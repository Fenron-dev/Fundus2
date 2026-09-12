import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/protection.dart';
import 'package:fundus_core/fundus_core.dart';

/// The protected shelf.
///
/// Hiding is a setting; unlocking happens once and lapses. What is tried here
/// is that hiding really hides — through the one funnel every list and count
/// comes through — and that the PIN is nowhere to be read.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late ProtectionController protection;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-protection-');
    final open = Directory('${root.path}/Hörbücher/Karl May/Der Schacht');
    await open.create(recursive: true);
    await File('${open.path}/01.mp3').writeAsBytes(List.filled(64, 1));
    final vault = await FundusLibrary.create(root);
    await for (final _ in vault.index()) {}
    // Ein Werk auf dem geschützten Regal.
    final work = vault.listWorks().single;
    await vault.updateWorkMetadata(
      workId: work.id,
      title: work.title,
      authors: [work.author],
      contentSensitivity: 'adult_explicit',
    );
    vault.close();

    library = LibraryController();
    settings = AppSettings.inMemory();
    protection = ProtectionController(settings: settings);
    await library.open(root);
    library.hides = protection.hides;
    library.refresh();
  });

  tearDown(() async {
    protection.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test('ohne Schutz ist alles zu sehen', () {
    expect(protection.mode, ProtectionMode.off);
    expect(library.works, hasLength(1));
    expect(protection.veils(library.works.single), isFalse);
  });

  test('unscharf heißt gelistet, aber verdeckt', () async {
    await protection.setMode(ProtectionMode.blur);
    library.refresh();

    expect(library.works, hasLength(1));
    expect(protection.veils(library.works.single), isTrue);
    expect(protection.hides(library.works.single), isFalse);
  });

  test('ausblenden nimmt das Werk aus jeder Liste', () async {
    await protection.setMode(ProtectionMode.hide);
    library.refresh();

    // Der Filter sitzt an der einen Stelle, durch die alles geht.
    expect(library.works, isEmpty);
  });

  test('die richtige PIN öffnet, die falsche nicht', () async {
    await protection.setMode(ProtectionMode.hide);
    await protection.setPin('2451');
    protection.lock();
    library.refresh();
    expect(library.works, isEmpty);

    expect(protection.unlock('0000'), isFalse);
    expect(library.works, isEmpty);

    expect(protection.unlock('2451'), isTrue);
    library.refresh();
    expect(library.works, hasLength(1));
  });

  test('die PIN steht nirgends im Klartext', () async {
    await protection.setPin('2451');

    expect(settings.protectionPin, isNot(contains('2451')));
    // Gesalzen: zweimal dieselbe PIN ergibt nicht denselben Eintrag.
    final first = settings.protectionPin;
    await protection.setPin('2451');
    expect(settings.protectionPin, isNot(first));
    expect(settings.protectionPin, startsWith('v2:'));
  });

  test('fünf falsche PINs drosseln weitere Versuche', () async {
    await protection.setPin('2451');
    protection.lock();
    for (var attempt = 0; attempt < 5; attempt++) {
      expect(protection.unlock('0000'), isFalse);
    }
    expect(protection.unlock('2451'), isFalse);
  });

  test('gesperrt wird beim Start, nicht beim Beenden', () async {
    await protection.setMode(ProtectionMode.hide);
    await protection.setPin('2451');
    expect(protection.isUnlocked, isTrue);

    // Ein neuer Controller auf denselben Einstellungen ist wieder zu.
    final afterRestart = ProtectionController(settings: settings);
    addTearDown(afterRestart.dispose);
    expect(afterRestart.isUnlocked, isFalse);
    expect(afterRestart.hasPin, isTrue);
  });

  test('Geräteauthentifizierung öffnet nur die laufende Sitzung', () async {
    await protection.setMode(ProtectionMode.hide);
    protection.lock();

    protection.unlockAuthenticatedSession();
    expect(protection.isUnlocked, isTrue);

    final afterRestart = ProtectionController(settings: settings);
    addTearDown(afterRestart.dispose);
    expect(afterRestart.isUnlocked, isFalse);
  });
}
