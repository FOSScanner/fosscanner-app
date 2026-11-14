import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Displays the saved result without rerunning any image processing.
class PagePreviewScreen extends StatelessWidget {
  const PagePreviewScreen({
    super.key,
    required this.imageBytes,
    required this.pageNumber,
  });

  final Uint8List imageBytes;
  final int pageNumber;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Page $pageNumber'),
      actions: [
        IconButton(
          tooltip: 'Edit page',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () {
            if (ModalRoute.of(context)?.isCurrent ?? false) {
              Navigator.of(context).pop(true);
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: SizedBox.expand(
          child: Image(
            image: ResizeImage(
              MemoryImage(imageBytes),
              width: 2048,
              height: 2048,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            semanticLabel: 'Preview of page $pageNumber',
            errorBuilder: (_, _, _) =>
                const Center(child: Text('Could not display this page.')),
          ),
        ),
      ),
    ),
  );
}
