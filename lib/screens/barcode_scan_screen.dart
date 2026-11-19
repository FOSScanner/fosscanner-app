import 'dart:async';

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:url_launcher/url_launcher.dart';

import '../services/app_settings.dart';
import '../services/cache_copies.dart';
import '../widgets/transient_message.dart';

class BarcodeScanResult {
  const BarcodeScanResult({required this.isValid, required this.text});

  final bool isValid;
  final String? text;
}

typedef BarcodeScanViewBuilder =
    Widget Function(
      BuildContext context,
      ValueChanged<BarcodeScanResult> onScan,
    );
typedef BarcodeClipboardWriter = Future<void> Function(String text);
typedef BarcodeUriLauncher = Future<bool> Function(Uri uri);

/// Picks an image and decodes a code in it. Returns null when no image was
/// picked, and an invalid result when the image holds no readable code.
typedef BarcodeImageScanner = Future<BarcodeScanResult?> Function();

// Icons wrapped so the reader's built-in buttons get tooltips and labels.
Widget _labeledIcon(IconData icon, String label) =>
    Tooltip(message: label, child: Icon(icon));

Widget _defaultScanView(
  BuildContext context,
  ValueChanged<BarcodeScanResult> onScan, {
  required int attempt,
  required ValueChanged<Exception?> onCameraCreated,
}) => ReaderWidget(
  key: ValueKey(attempt),
  onControllerCreated: (_, error) => onCameraCreated(error),
  onScan: (code) =>
      onScan(BarcodeScanResult(isValid: code.isValid, text: code.text)),
  // The screen offers its own gallery action, which reports images without
  // a code and removes the picker's copy of the image.
  showGallery: false,
  flashOnIcon: _labeledIcon(Icons.flash_on, 'Turn off flashlight'),
  flashOffIcon: _labeledIcon(Icons.flash_off, 'Turn on flashlight'),
  flashAlwaysIcon: _labeledIcon(Icons.flash_on, 'Turn off flashlight'),
  flashAutoIcon: _labeledIcon(Icons.flash_auto, 'Turn on flashlight'),
  toggleCameraIcon: _labeledIcon(Icons.switch_camera, 'Switch camera'),
  // cropPercent must stay 0 here: ReaderWidget's crop-indicator square only
  // lines up with the region it actually decodes when the widget is truly
  // full-screen. See khoren93/flutter_zxing#196.
  cropPercent: 0,
  // At cropPercent 0 the built-in overlay suggests tapping is required. The
  // aiming guide below is cosmetic; decoding always uses the whole frame.
  showScannerOverlay: false,
  // Common 1D formats need a more exhaustive per-frame decode attempt.
  tryHarder: true,
);

Future<void> _writeClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

Future<bool> _launchBarcodeUri(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<BarcodeScanResult?> _scanGalleryImage() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (file == null) return null;
  try {
    // The same decoder options as the camera stream.
    final code = await zx.readBarcodeImagePath(
      file,
      DecodeParams(
        imageFormat: ImageFormat.rgb,
        tryHarder: true,
        tryInverted: true,
        maxNumberOfSymbols: 1,
      ),
    );
    return BarcodeScanResult(isValid: code.isValid, text: code.text);
  } finally {
    // Android's picker copies the image into the app cache.
    unawaited(deleteImagePickerCopy(file.path));
  }
}

/// A live QR/barcode scanning mode, separate from the document-scan flow.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({
    super.key,
    this.scanViewBuilder,
    this.clipboardWriter = _writeClipboard,
    this.uriLauncher = _launchBarcodeUri,
    this.imageScanner = _scanGalleryImage,
    this.appSettingsOpener = openAppSettings,
  });

  final BarcodeScanViewBuilder? scanViewBuilder;
  final BarcodeClipboardWriter clipboardWriter;
  final BarcodeUriLauncher uriLauncher;
  final BarcodeImageScanner imageScanner;
  final AppSettingsOpener appSettingsOpener;

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  String? _latchedResult;
  String? _cameraError;
  bool _cameraAccessDenied = false;
  int _cameraAttempt = 0;
  bool _isScanningImage = false;
  // Set while the user is in the app's settings page, to retry on return.
  bool _retryOnResume = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _handleResume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _handleResume() {
    if (!_retryOnResume || !mounted) return;
    _retryOnResume = false;
    if (_cameraError != null) _retryCamera();
  }

  void _handleCameraCreated(Exception? error, int attempt) {
    if (!mounted || attempt != _cameraAttempt || error == null) return;
    final denied = switch (error) {
      CameraException(code: 'CameraAccessDenied') ||
      CameraException(code: 'CameraAccessDeniedWithoutPrompt') => true,
      _ => false,
    };
    final message = switch (error) {
      _ when denied => cameraAccessOffMessage,
      CameraException(code: 'CameraAccessRestricted') =>
        cameraAccessRestrictedMessage,
      _ => 'Could not start the camera. Try again.',
    };
    setState(() {
      _cameraError = message;
      _cameraAccessDenied = denied;
    });
  }

  void _retryCamera() {
    setState(() {
      _cameraError = null;
      _cameraAccessDenied = false;
      _cameraAttempt++;
    });
  }

  Future<void> _openSettings() async {
    _retryOnResume = true;
    final opened = await widget.appSettingsOpener();
    if (!opened) {
      _retryOnResume = false;
      if (mounted) showTransientMessage(context, 'Could not open settings.');
    }
  }

  /// Messages over the camera view sit above the reader's flashlight and
  /// camera buttons (48 px plus 10 px padding on each side) and share their
  /// dark style, whatever the app theme.
  void _showScanViewMessage(String message) => showTransientMessage(
    context,
    message,
    overCamera: true,
    margin: const EdgeInsets.fromLTRB(15, 5, 15, 48 + 2 * 10 + 10),
  );

  Future<void> _scanImage() async {
    if (_isScanningImage) return;
    setState(() => _isScanningImage = true);
    try {
      final scan = await widget.imageScanner();
      if (!mounted || scan == null) return;
      final text = scan.text;
      if (!scan.isValid || text == null || text.isEmpty) {
        _showScanViewMessage('No code found in this image.');
        return;
      }
      _handleScan(scan);
    } catch (_) {
      if (mounted) _showScanViewMessage('Could not read this image.');
    } finally {
      if (mounted) setState(() => _isScanningImage = false);
    }
  }

  Widget _buildCameraError(String message) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Camera unavailable',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _retryCamera,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                // After a lasting denial, Retry cannot ask again; only the
                // app's settings page can turn camera access back on.
                if (_cameraAccessDenied && canOpenAppSettings)
                  OutlinedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open settings'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Uri? get _resultUri {
    final result = _latchedResult;
    if (result == null) return null;
    final uri = Uri.tryParse(result);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  void _handleScan(BarcodeScanResult scan) {
    if (!mounted || _latchedResult != null) return;
    final text = scan.text;
    if (!scan.isValid || text == null || text.isEmpty) return;
    setState(() => _latchedResult = text);
  }

  void _dismissResult() {
    setState(() => _latchedResult = null);
  }

  Future<void> _copyResult() async {
    final result = _latchedResult;
    if (result == null) return;
    try {
      await widget.clipboardWriter(result);
      if (mounted) showTransientMessage(context, 'Copied to clipboard');
    } catch (_) {
      if (mounted) {
        showTransientMessage(context, 'Could not copy to clipboard.');
      }
    }
  }

  Future<void> _openResult() async {
    final uri = _resultUri;
    if (uri == null) return;
    try {
      final launched = await widget.uriLauncher(uri);
      if (!launched && mounted) {
        showTransientMessage(context, 'Could not open the link.');
      }
    } catch (_) {
      if (mounted) showTransientMessage(context, 'Could not open the link.');
    }
  }

  Widget _buildResultReview(String result) {
    final uri = _resultUri;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: const Key('barcode_result_scroll_view'),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (uri != null) ...[
                      Text(
                        'Destination host',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      SelectableText(
                        uri.host,
                        key: const Key('barcode_destination_host'),
                        textDirection: TextDirection.ltr,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text('Opening this link leaves FOSScanner.'),
                      const SizedBox(height: 24),
                      Text(
                        'Full URL',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                    ],
                    Semantics(
                      key: const Key('barcode_result_semantics'),
                      container: true,
                      liveRegion: true,
                      child: SelectableText(
                        result,
                        key: const Key('barcode_result_text'),
                        textDirection: uri == null ? null : TextDirection.ltr,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 12,
                overflowSpacing: 8,
                children: [
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Copy scanned result',
                    onTap: _copyResult,
                    child: ExcludeSemantics(
                      child: OutlinedButton.icon(
                        onPressed: _copyResult,
                        icon: const Icon(Icons.content_copy_outlined),
                        label: const Text('Copy'),
                      ),
                    ),
                  ),
                  if (uri != null)
                    Semantics(
                      container: true,
                      button: true,
                      label: 'Open scanned link',
                      onTap: _openResult,
                      child: ExcludeSemantics(
                        child: FilledButton.icon(
                          onPressed: _openResult,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _latchedResult;
    final cameraError = _cameraError;
    final cameraAttempt = _cameraAttempt;
    return Scaffold(
      appBar: AppBar(
        // Scales down rather than truncating at large text sizes.
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            result == null ? 'Scan QR code or barcode' : 'Scanned result',
          ),
        ),
        actions: [
          if (result == null)
            IconButton(
              onPressed: _isScanningImage ? null : _scanImage,
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: 'Scan an image',
            ),
          if (result != null)
            IconButton(
              onPressed: _dismissResult,
              icon: const Icon(Icons.qr_code_scanner_outlined),
              tooltip: 'Scan another',
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The reader draws nothing until its camera is running, which
          // takes a moment on opening and after returning from the image
          // picker; a dark backdrop then stands in for the preview instead
          // of the light page background.
          if (cameraError == null)
            const ColoredBox(
              key: Key('barcode_camera_backdrop'),
              color: Colors.black,
            ),
          if (cameraError == null)
            Offstage(
              // Keep the camera state, but hide its controls and semantics
              // while the user inspects the latched result.
              offstage: result != null,
              child:
                  widget.scanViewBuilder?.call(context, _handleScan) ??
                  _defaultScanView(
                    context,
                    _handleScan,
                    attempt: cameraAttempt,
                    onCameraCreated: (error) =>
                        _handleCameraCreated(error, cameraAttempt),
                  ),
            ),
          if (result == null && cameraError == null)
            IgnorePointer(
              child: Center(
                child: Container(
                  width: MediaQuery.sizeOf(context).shortestSide * 0.6,
                  height: MediaQuery.sizeOf(context).shortestSide * 0.6,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          if (result != null)
            Positioned.fill(child: _buildResultReview(result)),
          if (cameraError != null && result == null)
            Positioned.fill(child: _buildCameraError(cameraError)),
        ],
      ),
    );
  }
}
