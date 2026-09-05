import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/app/vault_access.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus_design/fundus_design.dart';

/// Ein Ordner, den macOS nur nach Rückfrage wieder hergibt.
final class RecordingAccess implements VaultAccess {
  final List<String> unlocked = [];
  final List<String> remembered = [];

  @override
  bool get isRequired => true;

  @override
  Future<void> remember(String path) async => remembered.add(path);

  @override
  Future<bool> unlock(String path) async {
    unlocked.add(path);
    return true;
  }
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late RecordingAccess access;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-access-');
    library = LibraryController();
    settings = AppSettings.inMemory();
    access = RecordingAccess();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          vaultAccess: access,
          child: const FundusShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('ein Ordner aus der Liste holt sich erst die Erlaubnis zurück', (
    tester,
  ) async {
    // Erst anlegen, damit dort etwas zu öffnen ist.
    final builder = LibraryController();
    await tester.runAsync(() async {
      await builder.open(root, createIfMissing: true);
    });
    builder.dispose();
    await settings.rememberVault(root.path);

    await pump(tester);
    await tester.tap(find.textContaining(root.path.split('/').last).first);
    await tester.pump();

    // Ohne diesen Schritt meldet macOS „Cannot open file" für einen Ordner,
    // der einwandfrei da ist.
    expect(access.unlocked, [root.path]);

    // Das Öffnen selbst läuft gegen die echte Platte und kommt in einem
    // Widget-Test nicht zurück; hier zählt der Schritt davor. Die Uhr wird
    // vorgestellt, damit die Wartezeit abläuft statt offen zu bleiben.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  testWidgets('ein Ordner mit Erlaubnis gilt als erreichbar', (tester) async {
    // Ein Pfad, den es hier nicht gibt — unter der Sandbox sieht die App
    // genau das, bis sie die Erlaubnis zurückholt.
    const elsewhere = '/Volumes/Media/Fundus2-Vault';
    await settings.rememberVault(elsewhere);
    await settings.setVaultBookmarks({elsewhere: 'irgendein-token'});

    await pump(tester);

    final tile = tester.widget<InkWell>(
      find.ancestor(
        of: find.text('Fundus2-Vault'),
        matching: find.byType(InkWell),
      ),
    );
    expect(
      tile.onTap,
      isNotNull,
      reason: 'ein hinterlegter Ordner darf nicht ausgegraut sein',
    );
  });
}
