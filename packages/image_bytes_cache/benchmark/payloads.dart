/// Synthetic payload sizes for store microbenches.
///
/// [smallBytes] sits under the VM transferable / web OPFS cut (64 KiB).
/// [largeBytes] sits at or above that cut so durable writes take the large-body
/// path. Patterns are deterministic so length and content stay stable across runs.
library;

import 'dart:typed_data';

/// Below the 64 KiB transferable / OPFS threshold.
const int smallBytes = 4 * 1024;

/// At or above the 64 KiB cut.
const int largeBytes = 96 * 1024;

/// Builds a deterministic payload of [length] bytes.
Uint8List payloadOf(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31) & 0xff;
  }
  return bytes;
}
