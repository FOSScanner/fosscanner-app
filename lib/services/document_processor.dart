/// Document edge detection + perspective correction. Backed by real OpenCV
/// (`opencv_dart`) on native platforms; on web (which `opencv_dart` doesn't
/// support, being FFI-based) this falls back to a no-op stub that passes
/// the photo through unchanged — see the dev plan for why.
library;

export 'document_processor_native.dart'
    if (dart.library.js_interop) 'document_processor_web.dart';
