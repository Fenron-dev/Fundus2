import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/app/storage_access.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_design/fundus_design.dart';

/// A stand-in for Android's "All files access".
final class FakeStorageAccess implements StorageAccess {
  FakeStorageAccess({this.required = true, this.granted = false});

  bool required;
  bool granted;
  int requests = 0;

  @override
  bool get isRequired => required;

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<bool> request() async {
    requests++;
    return granted;
  }

  @override
  Future<String?> storageRoot() async => '/storage/emulated/0';
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-storage-');
    library = LibraryController();
    settings = AppSettings.inMemory();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pumpVault(WidgetTester tester, StorageAccess storage) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          storage: storage,
          child: const FundusShell(),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  testWidgets('ohne Dateizugriff wird gefragt und dann erklärt', (
    tester,
  ) async {
    final storage = FakeStorageAccess(granted: false);
    await pumpVault(tester, storage);

    await tester.runAsync(() async {
      await tester.tap(find.text('Bibliothek öffnen'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(storage.requests, 1, reason: 'Es wurde gar nicht gefragt');
    // Und der Nutzer erfährt, warum nichts passiert ist.
    expect(find.textContaining('Dateizugriff'), findsWidgets);
    expect(library.isOpen, isFalse);
  });

  testWidgets('wo nichts zu fragen ist, wird nicht gefragt', (tester) async {
    final storage = FakeStorageAccess(required: false, granted: true);
    await pumpVault(tester, storage);

    await tester.runAsync(() async {
      await tester.tap(find.text('Bibliothek öffnen'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // Es geht direkt weiter zum Dateidialog — den es im Test nicht gibt, was
    // als Meldung erscheint statt als Absturz. Der Beweis: nach der Erlaubnis
    // wurde nicht gefragt.
    expect(storage.requests, 0);
    expect(find.textContaining('Dateizugriff'), findsNothing);
    expect(find.textContaining('Ordnerdialog'), findsWidgets);
  });

  test('auf allen anderen Plattformen ist nichts zu erteilen', () async {
    const storage = OpenStorageAccess();

    expect(storage.isRequired, isFalse);
    expect(await storage.isGranted(), isTrue);
    expect(await storage.storageRoot(), isNull);
  });
}
