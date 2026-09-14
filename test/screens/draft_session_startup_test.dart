import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fosscanner/main.dart';
import 'package:fosscanner/models/scanned_page.dart';
import 'package:fosscanner/screens/scanner_home_page.dart';
import 'package:fosscanner/services/draft_store.dart';

class _SessionDraftStore implements DraftStore, DraftSessionStore {
  final attempts = <Completer<void>>[];
  var loadCalls = 0;
  var saveCalls = 0;

  @override
  Future<void> acquireSession() {
    final attempt = Completer<void>();
    attempts.add(attempt);
    return attempt.future;
  }

  @override
  Future<List<ScannedPage>> load() async {
    loadCalls++;
    return const [];
  }

  @override
  Future<void> save(List<ScannedPage> pages) async => saveCalls++;

  @override
  Future<void> clear() async {}
}

void main() {
  testWidgets('acquires the draft session before mounting the scanner', (
    tester,
  ) async {
    final store = _SessionDraftStore();

    await tester.pumpWidget(FOSScannerApp(draftStore: store));

    expect(store.attempts, hasLength(1));
    expect(store.loadCalls, 0);
    expect(find.byType(ScannerHomePage), findsNothing);
    expect(find.byTooltip('Import from gallery'), findsNothing);
    store.attempts.single.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ScannerHomePage), findsOneWidget);
    expect(store.loadCalls, 1);
  });

  testWidgets('failed acquisition keeps the scanner closed and retries', (
    tester,
  ) async {
    final store = _SessionDraftStore();
    await tester.pumpWidget(FOSScannerApp(draftStore: store));
    expect(store.attempts, hasLength(1));
    store.attempts.single.completeError(
      StateError('private filesystem details'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ScannerHomePage), findsNothing);
    expect(store.loadCalls, 0);
    expect(store.saveCalls, 0);
    expect(find.textContaining('private filesystem details'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(store.attempts, hasLength(2));
    expect(find.text('Retry'), findsNothing);
    expect(store.loadCalls, 0);
    store.attempts.last.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ScannerHomePage), findsOneWidget);
    expect(store.loadCalls, 1);
  });

  testWidgets('contention explains how to reopen the draft', (tester) async {
    final store = _SessionDraftStore();
    await tester.pumpWidget(FOSScannerApp(draftStore: store));
    store.attempts.single.completeError(const DraftInUseException());
    await tester.pumpAndSettle();

    expect(find.text('Draft already open'), findsOneWidget);
    expect(
      find.text('Close the other FOSScanner window, then try again.'),
      findsOneWidget,
    );
    expect(find.byType(ScannerHomePage), findsNothing);
    expect(store.loadCalls, 0);
    expect(store.saveCalls, 0);
  });

  testWidgets('a replacement store must acquire its own session', (
    tester,
  ) async {
    final first = _SessionDraftStore();
    await tester.pumpWidget(FOSScannerApp(draftStore: first));
    first.attempts.single.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(FOSScannerApp(draftStore: first));
    expect(first.attempts, hasLength(1));

    final second = _SessionDraftStore();
    await tester.pumpWidget(FOSScannerApp(draftStore: second));
    expect(second.attempts, hasLength(1));
    expect(second.loadCalls, 0);
    expect(find.byType(ScannerHomePage), findsNothing);
    second.attempts.single.complete();
    await tester.pumpAndSettle();
    expect(second.loadCalls, 1);
  });

  testWidgets(
    'the busy screen remains usable with large text in a small window',
    (tester) async {
      tester.view.physicalSize = const Size(320, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _SessionDraftStore();
      await tester.pumpWidget(FOSScannerApp(draftStore: store));
      store.attempts.single.completeError(const DraftInUseException());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(store.attempts, hasLength(2));
      store.attempts.last.completeError(const DraftInUseException());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
