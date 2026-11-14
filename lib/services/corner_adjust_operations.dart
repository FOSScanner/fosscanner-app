import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart' show Offset, Size;

import '../models/scanned_page.dart';
import 'corner_geometry.dart';
import 'document_processor.dart';
import 'image_metadata.dart';

abstract interface class CornerAdjustOperations {
  Future<Size> decodeSize(Uint8List imageBytes);

  Future<List<Offset>?> detectCorners(Uint8List imageBytes);

  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  );

  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  });

  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  });
}

typedef _PreviewWorkerRequest = ({
  Uint8List imageBytes,
  List<double> cornerCoordinates,
});
typedef _FinalPreviewWorkerRequest = ({
  Uint8List imageBytes,
  int rotationQuarterTurns,
  double brightness,
  double contrast,
});
typedef _ExportWorkerRequest = ({
  Uint8List imageBytes,
  List<double> cornerCoordinates,
  PageFilter filter,
  int rotationQuarterTurns,
  double brightness,
  double contrast,
});

List<double> _serializeCorners(List<Offset> corners) => [
  for (final corner in corners) ...[corner.dx, corner.dy],
];

List<Offset> _deserializeCorners(List<double> coordinates) => [
  for (var i = 0; i < coordinates.length; i += 2)
    Offset(coordinates[i], coordinates[i + 1]),
];

List<double>? _detectCornersWorker(Uint8List imageBytes) {
  final corners = detectCorners(imageBytes);
  return corners == null ? null : _serializeCorners(corners);
}

Map<PageFilter, Uint8List> _buildPreviewsWorker(_PreviewWorkerRequest request) {
  final warped = warpDocument(
    request.imageBytes,
    _deserializeCorners(request.cornerCoordinates),
    maxPixels: maxPreviewWarpPixels,
    maxEdge: maxPreviewWarpEdge,
  );
  return {
    for (final filter in PageFilter.values) filter: applyFilter(warped, filter),
  };
}

Uint8List _buildFinalPreviewWorker(_FinalPreviewWorkerRequest request) {
  final rotated = rotateImage(request.imageBytes, request.rotationQuarterTurns);
  return adjustBrightnessContrast(
    rotated,
    brightness: request.brightness,
    contrast: request.contrast,
  );
}

Uint8List _processForExportWorker(_ExportWorkerRequest request) =>
    processDocument(
      request.imageBytes,
      _deserializeCorners(request.cornerCoordinates),
      filter: request.filter,
      rotationQuarterTurns: request.rotationQuarterTurns,
      brightness: request.brightness,
      contrast: request.contrast,
    );

class DefaultCornerAdjustOperations implements CornerAdjustOperations {
  const DefaultCornerAdjustOperations();

  @override
  Future<Size> decodeSize(Uint8List imageBytes) =>
      readEncodedImageSize(imageBytes);

  @override
  Future<List<Offset>?> detectCorners(Uint8List imageBytes) async {
    final coordinates = await compute(_detectCornersWorker, imageBytes);
    return coordinates == null ? null : _deserializeCorners(coordinates);
  }

  @override
  Future<Map<PageFilter, Uint8List>> buildPreviews(
    Uint8List imageBytes,
    List<Offset> corners,
  ) => compute(_buildPreviewsWorker, (
    imageBytes: imageBytes,
    cornerCoordinates: _serializeCorners(corners),
  ));

  @override
  Future<Uint8List> buildFinalPreview(
    Uint8List imageBytes, {
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) => compute(_buildFinalPreviewWorker, (
    imageBytes: imageBytes,
    rotationQuarterTurns: rotationQuarterTurns,
    brightness: brightness,
    contrast: contrast,
  ));

  @override
  Future<Uint8List> processForExport(
    Uint8List imageBytes,
    List<Offset> corners, {
    required PageFilter filter,
    required int rotationQuarterTurns,
    required double brightness,
    required double contrast,
  }) => compute(_processForExportWorker, (
    imageBytes: imageBytes,
    cornerCoordinates: _serializeCorners(corners),
    filter: filter,
    rotationQuarterTurns: rotationQuarterTurns,
    brightness: brightness,
    contrast: contrast,
  ));
}
