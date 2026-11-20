import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// Pages rendered so far out of the pages being rendered.
@immutable
class PdfImportProgress {
  const PdfImportProgress(this.completed, this.total);

  final int completed;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is PdfImportProgress &&
      other.completed == completed &&
      other.total == total;

  @override
  int get hashCode => Object.hash(completed, total);
}

/// Modal progress for rendering a PDF's pages. A dialog rather than inline
/// status, so a long import never shifts the page grid behind it.
///
/// Back and **Cancel** both call [onCancel] once; the caller closes the
/// dialog when rendering ends.
class PdfImportProgressDialog extends StatefulWidget {
  const PdfImportProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
  });

  /// Null until the document is open and its page count known.
  final ValueListenable<PdfImportProgress?> progress;
  final VoidCallback onCancel;

  @override
  State<PdfImportProgressDialog> createState() =>
      _PdfImportProgressDialogState();
}

class _PdfImportProgressDialogState extends State<PdfImportProgressDialog> {
  bool _cancelling = false;

  void _cancel() {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    widget.onCancel();
  }

  String _status(PdfImportProgress? progress) {
    if (_cancelling) return 'Canceling…';
    if (progress == null || progress.total <= 0) return 'Opening PDF…';
    final page = progress.completed < progress.total
        ? progress.completed + 1
        : progress.total;
    return 'Rendering page $page of ${progress.total}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: const Text('Importing PDF'),
        content: ValueListenableBuilder<PdfImportProgress?>(
          valueListenable: widget.progress,
          builder: (context, progress, _) {
            final status = _status(progress);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: _cancelling || progress == null || progress.total <= 0
                      ? null
                      : progress.completed / progress.total,
                ),
                const SizedBox(height: 16),
                // One line at every text size, so updates never resize the
                // dialog; the live region still reads the full status.
                Semantics(
                  liveRegion: true,
                  label: status,
                  child: ExcludeSemantics(
                    child: Text(
                      status,
                      key: const Key('pdf_import_status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: _cancelling ? null : _cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
