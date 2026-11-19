import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The export bar's "Share PDF" button while the document has [pages] pages
/// and exports [searchable] text.
///
/// The label is the same for every document; the page count and mode are in
/// the button's semantics value, which this matches.
Finder findShareButton(int pages, {bool searchable = false}) {
  final value = [
    '$pages ${pages == 1 ? 'page' : 'pages'}',
    if (searchable) 'searchable text',
  ].join(', ');
  return find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.value == value &&
        widget.child is FilledButton,
    description: 'Share PDF button for "$value"',
  );
}
