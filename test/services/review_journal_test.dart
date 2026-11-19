import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/services/review_journal.dart';

void main() {
  late Directory temp;
  late Directory root;
  late Directory cache;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('review_journal_test');
    root = Directory('${temp.path}/draft/review');
    cache = Directory('${temp.path}/cache')..createSync();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  String image(String name, [String content = 'jpeg']) =>
      (File('${cache.path}/$name')..writeAsStringSync(content)).path;

  List<String> journalFiles() => root.existsSync()
      ? [for (final entity in root.listSync()) entity.uri.pathSegments.last]
      : const [];

  test('moves app-owned images into the journal, in order', () async {
    final journal = FileReviewJournal(directory: root);
    final sources = [image('a.jpg', 'A'), image('b.jpg', 'B')];
    final kept = await journal.keep('pdf', sources);

    expect(kept, hasLength(2));
    expect(kept.every(journal.owns), isTrue);
    expect(sources.any((path) => File(path).existsSync()), isFalse);
    expect(kept.map((path) => File(path).readAsStringSync()), ['A', 'B']);

    // A new run (new object) finds the same review.
    final review = (await FileReviewJournal(directory: root).read())!;
    expect(review.source, 'pdf');
    expect(review.paths, kept);
    expect(review.unresumable, 0);
  });

  test('reviewed images are released and the rest stays', () async {
    final journal = FileReviewJournal(directory: root);
    final kept = await journal.keep('shared', [
      image('a.jpg'),
      image('b.jpg'),
      image('c.jpg'),
    ]);
    await journal.release(kept[0]);
    expect(File(kept[0]).existsSync(), isFalse);
    expect((await journal.read())!.paths, kept.sublist(1));

    await journal.release(kept[1]);
    await journal.release(kept[2]);
    expect(await journal.read(), isNull);
    // Nothing left behind once the review is over.
    expect(root.existsSync(), isFalse);
  });

  test('clear deletes every kept image', () async {
    final journal = FileReviewJournal(directory: root);
    await journal.keep('camera', [image('a.jpg')]);
    await journal.clear();
    expect(root.existsSync(), isFalse);
    expect(await journal.read(), isNull);
  });

  test('keeping images already in the journal reuses them', () async {
    final journal = FileReviewJournal(directory: root);
    final kept = await journal.keep('camera', [image('a.jpg'), image('b.jpg')]);
    // Resuming journals the same files again, as recovered images.
    final again = await journal.keep('recovered', kept.sublist(1));
    expect(again, kept.sublist(1));
    expect(File(kept[0]).existsSync(), isFalse);
    final review = (await journal.read())!;
    expect(review.source, 'recovered');
    expect(review.paths, again);
  });

  test('a new review replaces an earlier one', () async {
    final journal = FileReviewJournal(directory: root);
    final first = await journal.keep('pdf', [image('a.jpg')]);
    final second = await journal.keep('shared', [image('b.jpg')]);
    expect(File(first.single).existsSync(), isFalse);
    expect((await journal.read())!.paths, second);
  });

  test('gallery images are only counted, never copied', () async {
    final journal = FileReviewJournal(directory: root);
    final original = image('photo.jpg');
    await journal.notePending('gallery', 7);
    expect(journalFiles(), ['journal.json']);
    expect(File(original).existsSync(), isTrue);
    final review = (await journal.read())!;
    expect(review.source, 'gallery');
    expect(review.paths, isEmpty);
    expect(review.unresumable, 7);

    await journal.notePending('gallery', 6);
    expect((await journal.read())!.unresumable, 6);
    await journal.notePending('gallery', 0);
    expect(await journal.read(), isNull);
    expect(root.existsSync(), isFalse);
  });

  test('a file that cannot be moved keeps its own path', () async {
    final journal = FileReviewJournal(directory: root);
    final missing = '${cache.path}/missing.jpg';
    final kept = await journal.keep('shared', [missing, image('b.jpg')]);
    expect(kept.first, missing);
    expect(journal.owns(missing), isFalse);
    expect(journal.owns(kept.last), isTrue);
    expect((await journal.read())!.paths, [kept.last]);
  });

  test('only its own item files are owned', () async {
    final journal = FileReviewJournal(directory: root);
    final kept = await journal.keep('pdf', [image('a.jpg')]);
    expect(journal.owns(kept.single), isTrue);
    expect(journal.owns('${root.path}/journal.json'), isFalse);
    expect(journal.owns('${cache.path}/a.jpg'), isFalse);
    expect(journal.owns('${root.path}/../review/x.img'), isFalse);
    // release never deletes something it does not own.
    final other = image('other.jpg');
    await journal.release(other);
    expect(File(other).existsSync(), isTrue);
  });

  for (final damage in <String, String>{
    'not json': '{',
    'wrong version': jsonEncode({'version': 2, 'source': 'pdf', 'items': []}),
    'no source': jsonEncode({'version': 1, 'items': []}),
    'escaping names': jsonEncode({
      'version': 1,
      'source': 'pdf',
      'items': ['../../secret.jpg'],
    }),
  }.entries) {
    test('a damaged journal (${damage.key}) is discarded', () async {
      root.createSync(recursive: true);
      File('${root.path}/journal.json').writeAsStringSync(damage.value);
      File('${root.path}/item_1_0.img').writeAsStringSync('x');
      final secret = File('${temp.path}/secret.jpg')..writeAsStringSync('s');
      expect(await FileReviewJournal(directory: root).read(), isNull);
      expect(root.existsSync(), isFalse);
      expect(secret.existsSync(), isTrue);
    });
  }

  test('files without a manifest are removed', () async {
    root.createSync(recursive: true);
    File('${root.path}/item_1_0.img').writeAsStringSync('x');
    expect(await FileReviewJournal(directory: root).read(), isNull);
    expect(root.existsSync(), isFalse);
  });

  test('empty kept files are not offered again', () async {
    final journal = FileReviewJournal(directory: root);
    final kept = await journal.keep('pdf', [
      image('a.jpg', ''),
      image('b.jpg'),
    ]);
    expect((await journal.read())!.paths, [kept.last]);
  });
}
