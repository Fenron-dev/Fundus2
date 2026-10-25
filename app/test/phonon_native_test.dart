import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/phonon_native.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('fehlender Modellordner startet kein ungewolltes Audio', () async {
    final temp = await Directory.systemTemp.createTemp('fundus-phonon-');
    addTearDown(() => temp.delete(recursive: true));
    await expectLater(
      PhononNativeEngine.open(
        modelDirectory: '${temp.path}/nicht-installiert',
        language: SpeechLanguage.english,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('unvollständiges CPU-Modell wird vor dem Laden abgewiesen', () async {
    if (Platform.isMacOS) {
      return; // Apple benötigt stattdessen ein Core-ML-Bundle.
    }
    final temp = await Directory.systemTemp.createTemp('fundus-phonon-');
    addTearDown(() => temp.delete(recursive: true));
    await expectLater(
      PhononNativeEngine.open(
        modelDirectory: temp.path,
        language: SpeechLanguage.english,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('unvollständig'),
        ),
      ),
    );
  });
}
