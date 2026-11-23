import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/corner_adjust_screen.dart';
import 'package:fosscanner/services/draft_store.dart';

const fixtureCorners = [
  Offset.zero,
  Offset(599, 0),
  Offset(599, 899),
  Offset(0, 899),
];

/// Synthetic geometry and text only. Never replace this with a user's scan.
Future<Uint8List> syntheticDocument() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
  final title = TextPainter(
    text: const TextSpan(
      text: 'SYNTHETIC DOCUMENT',
      style: TextStyle(fontFamily: 'Roboto', color: Colors.black, fontSize: 32),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  title.paint(canvas, const Offset(40, 50));
  title.dispose();
  final paint = Paint()..color = const Color(0xff404040);
  for (var row = 0; row < 18; row++) {
    canvas.drawRect(
      Rect.fromLTWH(40, 150 + row * 32, row % 3 == 0 ? 420 : 500, 5),
      paint,
    );
  }
  canvas.drawRect(
    const Rect.fromLTWH(40, 760, 140, 80),
    Paint()..color = Colors.blueGrey,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(600, 900);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

enum PreviewFixtureState { ready, updating, failed }

class FixtureOperations implements CornerAdjustOperations {
  FixtureOperations(this.bytes);
  final Uint8List bytes;
  PreviewFixtureState previewState = PreviewFixtureState.ready;
  final pending = Completer<Uint8List>();

  @override
  Future<Size> decodeSize(Uint8List bytes) async => const Size(600, 900);
  @override
  Future<List<Offset>?> detectCorners(Uint8List bytes) async => fixtureCorners;
  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List bytes,
    List<Offset> corners,
  ) async => {for (final filter in PageFilter.values) filter: bytes};
  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List bytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async {
    switch (previewState) {
      case PreviewFixtureState.ready:
        return bytes;
      case PreviewFixtureState.updating:
        return pending.future;
      case PreviewFixtureState.failed:
        throw StateError('Synthetic preview failure');
    }
  }

  @override
  Future<Uint8List> processForExport(
    Uint8List bytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) async => bytes;
}

class FixtureDraftSession implements DraftSessionStore {
  FixtureDraftSession({this.fail = false});
  final bool fail;
  final waiting = Completer<void>();
  @override
  Future<void> acquireSession() async {
    if (fail) throw StateError('Synthetic storage failure');
    return waiting.future;
  }
}
