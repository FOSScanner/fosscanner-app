import 'dart:convert';
import 'dart:io';

import 'package:fosscanner/services/draft_session.dart';
import 'package:fosscanner/services/draft_session_lock.dart';

Future<void> main(List<String> arguments) async {
  final lock = DraftSessionLock(Directory(arguments.single));
  await for (final command
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (command == 'quit') return;
    try {
      await lock.acquire();
      stdout.writeln('acquired');
    } on DraftInUseException {
      stdout.writeln('busy');
    } on FileSystemException {
      stdout.writeln('storage-error');
    }
  }
}
