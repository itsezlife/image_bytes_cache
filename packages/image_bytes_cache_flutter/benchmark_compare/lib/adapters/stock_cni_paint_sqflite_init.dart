/// VM sqflite_ffi init + temp roots for stock CNI paint.
library;

import 'dart:io' as io;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _sqfliteFfiReady = false;

void ensureSqfliteFfi() {
  if (_sqfliteFfiReady) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _sqfliteFfiReady = true;
}

Future<String> createTempRoot(String prefix) async {
  final root = await io.Directory.systemTemp.createTemp(prefix);
  return root.path;
}

Future<void> deleteRootIfExists(String path) async {
  final dir = io.Directory(path);
  if (dir.existsSync()) {
    await dir.delete(recursive: true);
  }
}
