@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:fosscanner/services/document_processor_native.dart';

void main() {
  test('warpDocument forwards an explicit output budget', () {
    final input = File('assets/icon/icon.png').readAsBytesSync();
    final output = warpDocument(
      input,
      const [
        Offset.zero,
        Offset(10000, 0),
        Offset(10000, 5000),
        Offset(0, 5000),
      ],
      maxPixels: 100000,
      maxEdge: 400,
    );
    final decoded = cv.imdecode(output, cv.IMREAD_COLOR);
    try {
      expect(decoded.cols * decoded.rows, lessThanOrEqualTo(100000));
      expect(decoded.cols, lessThanOrEqualTo(400));
      expect(decoded.rows, lessThanOrEqualTo(400));
    } finally {
      decoded.dispose();
    }
  });

  test('the export pipeline can run in a worker isolate', () async {
    final input = File('assets/icon/icon.png').readAsBytesSync();
    const corners = [
      Offset.zero,
      Offset(1023, 0),
      Offset(1023, 511),
      Offset(0, 511),
    ];
    final expected = adjustBrightnessContrast(
      rotateImage(
        applyFilter(warpDocument(input, corners), PageFilter.grayscale),
        1,
      ),
      brightness: 10,
      contrast: 1.1,
    );

    final output = await Isolate.run(
      () => processDocument(
        input,
        corners,
        filter: PageFilter.grayscale,
        rotationQuarterTurns: 1,
        brightness: 10,
        contrast: 1.1,
      ),
    );
    final decoded = cv.imdecode(output, cv.IMREAD_COLOR);
    try {
      expect(output, orderedEquals(expected));
      expect(decoded.cols, 511);
      expect(decoded.rows, 1023);
    } finally {
      decoded.dispose();
    }
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
