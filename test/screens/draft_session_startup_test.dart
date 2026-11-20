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
  testWidgets(
    'startup and failure respect cutouts and recovery stays reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 220);
      tester.view.padding = const FakeViewPadding(
        left: 38,
        right: 24,
        bottom: 20,
      );
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final store = _SessionDraftStore();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: FOSScannerApp(draftStore: store),
        ),
      );
      // The app creates its own MediaQuery; set the system text scale as well.
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      final progress = tester.getRect(find.byType(CircularProgressIndicator));
      expect(progress.left, greaterThanOrEqualTo(38));
      expect(progress.right, lessThanOrEqualTo(576));
      store.attempts.single.completeError(StateError('private storage path'));
      await tester.pumpAndSettle();
      final retry = find.widgetWithText(FilledButton, 'Retry');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      final rect = tester.getRect(retry);
      expect(rect.left, greaterThanOrEqualTo(38));
      expect(rect.right, lessThanOrEqualTo(576));
      expect(rect.bottom, lessThanOrEqualTo(200));
      expect(retry.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
