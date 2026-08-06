import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/scanned_page.dart';
import 'corner_adjust_screen.dart';

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({super.key});

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

// Assumed resolution (dots per inch) of a warped page's pixel dimensions,
// used only to turn pixels into a printable-sized PDF page. It doesn't
// need to be exact — it just keeps pages roughly letter/A4-scale instead
// of pixel-count-as-points producing an absurdly large physical page.
const _scanDpi = 150.0;

class _ScannerHomePageState extends State<ScannerHomePage> {
  final List<ScannedPage> _pages = [];
  final ImagePicker _picker = ImagePicker();
  bool _isGeneratingPdf = false;

  // Best-effort cleanup: FOSScanner doesn't persist scanned pages, so the
  // temp file image_picker writes on capture is deleted the moment we've
  // read its bytes into memory.
  Future<void> _deleteFileQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Nothing actionable if cleanup fails; the OS will reclaim temp
      // storage eventually regardless.
    }
  }

  Future<void> _captureImage() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
    if (photo == null) return;

    final bytes = await photo.readAsBytes();
    _deleteFileQuietly(photo.path);

    if (kIsWeb) {
      // opencv_dart doesn't support web; use the photo as-is rather than
      // offering a detect/adjust flow we can't actually run.
      setState(() {
        _pages.add(ScannedPage(originalBytes: bytes, corners: const [], processedBytes: bytes));
      });
      return;
    }

    if (!mounted) return;
    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(builder: (_) => CornerAdjustScreen(originalBytes: bytes)),
    );
    if (result != null) {
      setState(() => _pages.add(result));
    }
  }

  Future<void> _editPage(int index) async {
    // No detect/adjust flow on web (see _captureImage) — nothing to edit.
    if (kIsWeb) return;

    final page = _pages[index];
    final result = await Navigator.of(context).push<ScannedPage>(
      MaterialPageRoute(
        builder: (_) => CornerAdjustScreen(
          originalBytes: page.originalBytes,
          initialCorners: page.corners,
          initialFilter: page.filter,
        ),
      ),
    );
    if (result != null) {
      setState(() => _pages[index] = result);
    }
  }

  void _removePage(int index) {
    setState(() => _pages.removeAt(index));
  }

  void _clearPages() {
    setState(() => _pages.clear());
  }

  Future<void> _generateAndSharePdf() async {
    if (_pages.isEmpty) return;

    setState(() {
      _isGeneratingPdf = true;
    });

    try {
      final pdf = pw.Document();

      for (final page in _pages) {
        final image = pw.MemoryImage(page.processedBytes);
        // Size the page to the image's own aspect ratio (at an assumed
        // scan resolution, so the physical page size stays reasonable)
        // instead of a fixed PdfPageFormat.a4 — that letterboxed the
        // image inside A4's fixed proportions (plus a built-in ~2cm
        // margin on top), which is exactly the "extra white border
        // around the selected document" users were seeing.
        final pageFormat = PdfPageFormat(
          image.width! / _scanDpi * PdfPageFormat.inch,
          image.height! / _scanDpi * PdfPageFormat.inch,
        );
        pdf.addPage(
          pw.Page(
            pageFormat: pageFormat,
            margin: pw.EdgeInsets.zero,
            build: (pw.Context context) => pw.Image(image, fit: pw.BoxFit.fill),
          ),
        );
      }

      // Share directly from bytes: no temp file needed, and no on-disk
      // trace of the document is ever created by the app itself.
      final pdfBytes = await pdf.save();
      final fileName = 'FOSScanner_${DateTime.now().millisecondsSinceEpoch}.pdf';

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(pdfBytes, name: fileName, mimeType: 'application/pdf')],
          text: 'Document scanned with FOSScanner',
          // On web, sharing needs a secure context (HTTPS/localhost); when
          // unavailable, share_plus falls back to a plain browser download
          // so the user still gets their PDF instead of hitting a dead end.
          downloadFallbackEnabled: true,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating PDF: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPdf = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FOSScanner'),
        actions: [
          if (_pages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: _clearPages,
              tooltip: 'Clear all',
            ),
        ],
      ),
      body: _pages.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.camera_alt, size: 80, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'Ready to Scan',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Tap the camera button to add your first document. FOSS & Privacy-first: everything is processed on your device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.7,
              ),
              itemCount: _pages.length,
              itemBuilder: (context, index) {
                final page = _pages[index];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _editPage(index),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          page.processedBytes,
                          fit: BoxFit.cover,
                        ),
                        Positioned(
                          top: 8,
                          left: 8,
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.white),
                              onPressed: () => _removePage(index),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _captureImage,
        tooltip: 'Capture Image',
        child: const Icon(Icons.camera_alt),
      ),
      bottomNavigationBar: _pages.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _isGeneratingPdf ? null : _generateAndSharePdf,
                  icon: _isGeneratingPdf
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf),
                  label: Text(
                    _isGeneratingPdf
                        ? 'Generating PDF...'
                        : 'Save as PDF (${_pages.length} pages)',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
