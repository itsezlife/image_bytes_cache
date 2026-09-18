import 'dart:async';
import 'dart:isolate';

/// Handler invoked once on a spawned isolate after the control channel is up.
///
/// [payload] is the value passed to [IsolateController.spawn]. [messages] is
/// the broadcast stream of host→worker requests. [send] pushes a typed reply
/// back to the host's [IsolateController.stream].
///
/// The handler owns the worker loop for the isolate's lifetime. When it
/// returns (normally or by throw), the entry point sends `#exit` and the host
/// tears the controller down.
typedef IsolateHandler<Payload, In, Out> =
    FutureOr<void> Function(
      Payload payload,
      Stream<In> messages,
      void Function(Out out) send,
    );

/// Long-lived isolate facade: spawn once, send typed requests, read typed
/// replies, close with kill + subscription cancel.
///
/// ## Ownership
///
/// The host that calls [spawn] owns the returned controller. Call [close]
/// exactly when the resource is done; [close] is safe to invoke more than
/// once from the host side only if the host stops using [add] / [stream]
/// afterward (this type does not itself guard double-[close]).
///
/// ## Protocol
///
/// 1. Host spawns with [spawn]; entry point replies with a [SendPort].
/// 2. Host [add]s `In` values; worker handler receives them on [messages].
/// 3. Worker [send]s `Out` values; host observes them on [stream].
/// 4. Non-payload control: `null` is the watchdog ping echo; `#exit` means
///    the handler finished and the host should tear down.
///
/// ## Watchdog
///
/// A 1s timer pings the isolate. If sent pings exceed received echoes by more
/// than five, the host assumes the worker is dead and [close]s. Counters wrap
/// at `1 << 16` so they do not grow without bound on a long-lived worker.
/// [close] (watchdog or `#exit`) closes [stream]; hosts that map replies to
/// pending completers must fail those completers on stream done/error so RPCs
/// do not hang (VM blob store does this).
///
/// ## Why this shape
///
/// VM durable blob IO needs a long-lived worker so small payload writes do not
/// pay per-op spawn cost and sync `dart:io` stays off the UI isolate. Do not
/// invent a second request/response protocol for that path. Reuse this
/// spawn / add / stream / close contract.
final class IsolateController<In, Out> {
  IsolateController._({
    required this.stream,
    required this.add,
    required this.close,
  });

  /// Typed replies from the worker. Broadcast; listen before [add]ing work
  /// that expects a response.
  final Stream<Out> stream;

  /// Sends a typed request to the worker. Must not be called after [close].
  final void Function(In data) add;

  /// Cancels the watchdog, closes ports/subscriptions, and [Isolate.kill]s
  /// the worker with [Isolate.immediate] so a worker blocked in sync IO cannot
  /// outlive the host. Closes [stream] so hosts can fail pending RPC
  /// completers; this type does not track host-side request IDs.
  final void Function() close;

  static Future<void> _$entryPoint<Payload, In, Out>(
    _IsolateArgument<Payload, In, Out> argument,
  ) async {
    final receivePort = ReceivePort();
    argument.sendPort.send(receivePort.sendPort);
    try {
      await argument(receivePort);
    } finally {
      argument.sendPort.send(#exit);
    }
  }

  /// Spawns a named isolate running [handler] with [payload].
  ///
  /// Completes when the worker has published its [SendPort]. Fatal isolate
  /// errors kill the isolate (`errorsAreFatal: true`).
  static Future<IsolateController<In, Out>> spawn<Payload, In, Out>({
    required IsolateHandler<Payload, In, Out> handler,
    required Payload payload,
    required String name,
  }) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn<_IsolateArgument<Payload, In, Out>>(
      _$entryPoint<Payload, In, Out>,
      _IsolateArgument<Payload, In, Out>(
        handler: handler,
        payload: payload,
        sendPort: receivePort.sendPort,
      ),
      errorsAreFatal: true,
      debugName: name,
    );

    final outputController = StreamController<Out>.broadcast();
    late final StreamSubscription<Object?> rcvSubscription;
    late final Timer watchdog;

    void close() {
      watchdog.cancel();
      receivePort.close();
      rcvSubscription.cancel().ignore();
      outputController.close().ignore();
      isolate.kill(priority: Isolate.immediate);
    }

    // Two counters + threshold (sent − received > 5 ⇒ dead), not a single bool.
    var $send = 0, $receive = 0;
    watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if ($send > $receive + 5) return close();
      $send++;
      isolate.ping(
        receivePort.sendPort,
        response: null,
        priority: Isolate.immediate,
      );
    });

    final completer = Completer<SendPort>();
    rcvSubscription = receivePort.listen(
      (message) {
        if (message is Out) {
          outputController.add(message);
        } else if (message == null) {
          $receive++;
          const max = 1 << 16;
          if ($receive >= max) {
            $send = $receive = 0;
          }
        } else if (message is SendPort) {
          completer.complete(message);
        } else if (message == #exit) {
          close();
        }
      },
      onError: outputController.addError,
      cancelOnError: false,
    );

    final sendPort = await completer.future;

    return IsolateController._(
      add: sendPort.send,
      stream: outputController.stream,
      close: close,
    );
  }
}

final class _IsolateArgument<Payload, In, Out> {
  _IsolateArgument({
    required this.handler,
    required this.payload,
    required this.sendPort,
  });

  final IsolateHandler<Payload, In, Out> handler;

  final Payload payload;

  final SendPort sendPort;

  FutureOr<void> call(Stream<Object?> receiveStream) => handler(
    payload,
    receiveStream.where((e) => e is In).cast<In>().asBroadcastStream(),
    sendPort.send,
  );
}
