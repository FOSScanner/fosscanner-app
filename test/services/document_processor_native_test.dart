@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/services/document_processor_native.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

Future<Uint8List> _drawPng(
  int width,
  int height,
  void Function(Canvas canvas) draw,
) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<({int width, int height, int red, int green, int blue})> _samplePixel(
  Uint8List bytes,
  int x,
  int y,
) async {
  final codec = await instantiateImageCodec(bytes);
  FrameInfo? frame;
  try {
    frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ImageByteFormat.rawRgba);
    final rgba = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final offset = (y * frame.image.width + x) * 4;
    return (
      width: frame.image.width,
      height: frame.image.height,
      red: rgba[offset],
      green: rgba[offset + 1],
      blue: rgba[offset + 2],
    );
  } finally {
    frame?.image.dispose();
    codec.dispose();
  }
}

void main() {
  test('detectCorners finds a synthetic high-contrast rectangle', () async {
    final input = await _drawPng(600, 400, (canvas) {
      canvas.drawColor(const Color(0xff000000), BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTRB(80, 60, 520, 340),
        Paint()..color = const Color(0xffffffff),
      );
    });

    final corners = detectCorners(input);

    expect(corners, isNotNull);
    const expected = [
      Offset(80, 60),
      Offset(519, 60),
      Offset(519, 339),
      Offset(80, 339),
    ];
    for (var i = 0; i < expected.length; i++) {
      expect(
        (corners![i] - expected[i]).distance,
        lessThan(12),
        reason: 'corner $i',
      );
    }
  });

  test('warpDocument produces a useful result within a custom budget', () {
    final input = File('assets/icon/icon.png').readAsBytesSync();
    final output = warpDocument(
      input,
      const [Offset.zero, Offset(799, 0), Offset(799, 399), Offset(0, 399)],
      maxPixels: 50000,
      maxEdge: 300,
    );
    final decoded = cv.imdecode(output, cv.IMREAD_COLOR);
    try {
      expect(decoded.cols, 300);
      expect(decoded.rows, 150);
      expect(decoded.cols / decoded.rows, closeTo(2, 0.02));
      expect(decoded.cols * decoded.rows, greaterThanOrEqualTo(40000));
      expect(decoded.cols * decoded.rows, lessThanOrEqualTo(50000));
    } finally {
      decoded.dispose();
    }
  });

  test('warpDocument preserves nonuniform source-corner orientation', () async {
    final input = await _drawPng(160, 120, (canvas) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 80, 60),
        Paint()..color = const Color(0xffff0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(80, 0, 80, 60),
        Paint()..color = const Color(0xff00ff00),
      );
      canvas.drawRect(
        const Rect.fromLTWH(80, 60, 80, 60),
        Paint()..color = const Color(0xff0000ff),
      );
      canvas.drawRect(
        const Rect.fromLTWH(0, 60, 80, 60),
        Paint()..color = const Color(0xffffff00),
      );
    });

    final output = warpDocument(input, const [
      Offset(20, 10),
      Offset(145, 25),
      Offset(130, 110),
      Offset(30, 95),
    ]);
    final dimensions = await _samplePixel(output, 5, 5);
    final topRight = await _samplePixel(output, dimensions.width - 6, 5);
    final bottomRight = await _samplePixel(
      output,
      dimensions.width - 6,
      dimensions.height - 6,
    );
    final bottomLeft = await _samplePixel(output, 5, dimensions.height - 6);

    expect(dimensions.red, greaterThan(dimensions.green + 80));
    expect(dimensions.red, greaterThan(dimensions.blue + 80));
    expect(topRight.green, greaterThan(topRight.red + 80));
    expect(topRight.green, greaterThan(topRight.blue + 80));
    expect(bottomRight.blue, greaterThan(bottomRight.red + 80));
    expect(bottomRight.blue, greaterThan(bottomRight.green + 80));
    expect(bottomLeft.red, greaterThan(bottomLeft.blue + 80));
    expect(bottomLeft.green, greaterThan(bottomLeft.blue + 80));
  });

  test('grayscale creates independently verifiable neutral pixels', () async {
    final input = await _drawPng(40, 30, (canvas) {
      canvas.drawColor(const Color.fromARGB(255, 30, 90, 150), BlendMode.src);
    });

    final pixel = await _samplePixel(
      applyFilter(input, PageFilter.grayscale),
      20,
      15,
    );

    expect((pixel.red - pixel.green).abs(), lessThanOrEqualTo(3));
    expect((pixel.green - pixel.blue).abs(), lessThanOrEqualTo(3));
    expect(pixel.red, closeTo(79, 8));
  });

  test(
    'brightness changes pixels by the requested independent amount',
    () async {
      final input = await _drawPng(40, 30, (canvas) {
        canvas.drawColor(const Color.fromARGB(255, 50, 50, 50), BlendMode.src);
      });

      final pixel = await _samplePixel(
        adjustBrightnessContrast(input, brightness: 40, contrast: 1),
        20,
        15,
      );

      expect(pixel.red, closeTo(90, 8));
      expect(pixel.green, closeTo(90, 8));
      expect(pixel.blue, closeTo(90, 8));
    },
  );

  test('clockwise rotation moves the left half to the top', () async {
    final input = await _drawPng(40, 20, (canvas) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 20, 20),
        Paint()..color = const Color(0xffff0000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(20, 0, 20, 20),
        Paint()..color = const Color(0xff0000ff),
      );
    });

    final output = rotateImage(input, 1);
    final top = await _samplePixel(output, 10, 5);
    final bottom = await _samplePixel(output, 10, 35);

    expect((top.width, top.height), (20, 40));
    expect(top.red, greaterThan(top.blue + 100));
    expect(bottom.blue, greaterThan(bottom.red + 100));
  });

  test('the export pipeline can run in a worker isolate', () async {
    final input = await _drawPng(200, 100, (canvas) {
      canvas.drawColor(const Color.fromARGB(255, 30, 90, 150), BlendMode.src);
    });
    const corners = [
      Offset.zero,
      Offset(199, 0),
      Offset(199, 99),
      Offset(0, 99),
    ];

    final output = await Isolate.run(
      () => processDocument(
        input,
        corners,
        filter: PageFilter.grayscale,
        rotationQuarterTurns: 1,
        brightness: 20,
        contrast: 1,
      ),
    );
    final pixel = await _samplePixel(output, 49, 99);

    expect((pixel.width, pixel.height), (99, 199));
    expect((pixel.red - pixel.green).abs(), lessThanOrEqualTo(3));
    expect((pixel.green - pixel.blue).abs(), lessThanOrEqualTo(3));
    expect(pixel.red, closeTo(99, 12));
  });

  test('auto-enhance repeatedly returns a decodable image', () {
    final input = File('assets/icon/icon.png').readAsBytesSync();

    for (var iteration = 0; iteration < 3; iteration++) {
      final output = applyFilter(input, PageFilter.autoEnhance);
      final decoded = cv.imdecode(output, cv.IMREAD_COLOR);
      try {
        expect(decoded.cols, 1024, reason: 'iteration $iteration width');
        expect(decoded.rows, 1024, reason: 'iteration $iteration height');
      } finally {
        decoded.dispose();
      }
    }
  });
}
