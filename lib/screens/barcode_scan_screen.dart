import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:url_launcher/url_launcher.dart';

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

Widget _defaultScanView(
  BuildContext context,
  ValueChanged<BarcodeScanResult> onScan,
) => ReaderWidget(
  onScan: (code) =>
      onScan(BarcodeScanResult(isValid: code.isValid, text: code.text)),
  showGallery: true,
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

/// A live QR/barcode scanning mode, separate from the document-scan flow.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({
    super.key,
    this.scanViewBuilder = _defaultScanView,
    this.clipboardWriter = _writeClipboard,
    this.uriLauncher = _launchBarcodeUri,
  });

  final BarcodeScanViewBuilder scanViewBuilder;
  final BarcodeClipboardWriter clipboardWriter;
  final BarcodeUriLauncher uriLauncher;

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  String? _latchedResult;

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

  @override
  Widget build(BuildContext context) {
    final result = _latchedResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR / Barcode')),
      body: Stack(
        children: [
          widget.scanViewBuilder(context, _handleScan),
          if (result == null)
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
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Card(
                  margin: const EdgeInsets.all(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Semantics(
                                container: true,
                                liveRegion: true,
                                label: 'Scanned code result: $result',
                                child: ExcludeSemantics(
                                  child: Text(
                                    result,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Dismiss and keep scanning',
                              onPressed: _dismissResult,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (_resultUri != null) ...[
                              Expanded(
                                child: Semantics(
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
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Semantics(
                                container: true,
                                button: true,
                                label: 'Copy scanned result',
                                onTap: _copyResult,
                                child: ExcludeSemantics(
                                  child: OutlinedButton.icon(
                                    onPressed: _copyResult,
                                    icon: const Icon(Icons.copy),
                                    label: const Text('Copy'),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
