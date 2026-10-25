import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';

void main() {
  test(
    'Sprach- und Stimmenwahl bleibt lokal nach Werk und Sprache getrennt',
    () async {
      final settings = AppSettings.inMemory();
      addTearDown(settings.dispose);

      await settings.setSpeechLanguageOverride('novel-en', 'en');
      await settings.setSpeechVoice('novel-en', 'en', 'english-female');
      await settings.setSpeechVoice('novel-en', 'de', 'german-default');

      expect(settings.speechLanguageOverride('novel-en'), 'en');
      expect(settings.speechLanguageOverride('other-work'), isNull);
      expect(settings.speechVoice('novel-en', 'en'), 'english-female');
      expect(settings.speechVoice('novel-en', 'de'), 'german-default');

      await settings.setSpeechLanguageOverride('novel-en', null);
      expect(settings.speechLanguageOverride('novel-en'), isNull);
    },
  );
}
