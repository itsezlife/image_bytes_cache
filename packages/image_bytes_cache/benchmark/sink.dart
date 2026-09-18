import 'dart:typed_data';

/// Folds returned bytes into an int so the optimizer cannot dead-code cache work.
int sinkBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return 0;
  return bytes.length ^ bytes[0] ^ bytes[bytes.length - 1];
}
