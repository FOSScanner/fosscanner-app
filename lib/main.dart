import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const FOSScannerApp());
}

class FOSScannerApp extends StatelessWidget {
  const FOSScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FOSScanner',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const ScannerHomePage(),
    );
  }
}

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({super.key});

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

class _ScannerHomePageState extends State<ScannerHomePage> {
  final List<XFile> _images = [];
  final ImagePicker _picker = ImagePicker();
  bool _isGeneratingPdf = false;

  Future<void> _captureImage() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
    if (photo != null) {
      setState(() {
        _images.add(photo);
      });
    }
  }

  // Best-effort cleanup: FOSScanner doesn't persist scanned pages, so any
  // temp file backing them is deleted as soon as it's no longer needed.
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

  void _removeImage(int index) {
    final removed = _images[index];
    setState(() {
      _images.removeAt(index);
    });
    _deleteFileQuietly(removed.path);
  }

  void _clearImages() {
    final removed = List<XFile>.from(_images);
    setState(() {
      _images.clear();
    });
    for (final image in removed) {
      _deleteFileQuietly(image.path);
    }
  }

  @override
  void dispose() {
    for (final image in _images) {
      _deleteFileQuietly(image.path);
    }
    super.dispose();
  }

  Future<void> _generateAndSharePdf() async {
    if (_images.isEmpty) return;

    setState(() {
      _isGeneratingPdf = true;
    });

    try {
      final pdf = pw.Document();

      for (final imageFile in _images) {
        final imageBytes = await imageFile.readAsBytes();
        final image = pw.MemoryImage(imageBytes);

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            build: (pw.Context context) {
              return pw.Center(
                child: pw.Image(image, fit: pw.BoxFit.contain),
              );
            },
          ),
        );
      }

      // Share directly from bytes: no temp file needed, and no on-disk
      // trace of the document is ever created by the app itself. This also
      // sidesteps path_provider/dart:io, which don't work on web.
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
          if (_images.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: _clearImages,
              tooltip: 'Clear all',
            ),
        ],
      ),
      body: _images.isEmpty
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
              itemCount: _images.length,
              itemBuilder: (context, index) {
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(_images[index].path),
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
                            onPressed: () => _removeImage(index),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _captureImage,
        tooltip: 'Capture Image',
        child: const Icon(Icons.camera_alt),
      ),
      bottomNavigationBar: _images.isNotEmpty
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
                        : 'Save as PDF (${_images.length} pages)',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
