import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/media/speech_profile.dart';

void main() {
  test(
    'multiple profiles reuse paths and dictionaries merge below per-work overrides',
    () async {
      const english = SpeechProfile(
        id: 'en-1',
        name: 'English narrator',
        language: 'en',
        modelDirectory: '/models/en',
        voicesDirectory: '/voices',
        voice: 'Alice',
        dictionaryIds: ['names'],
      );
      final settings = AppSettings.inMemory();
      addTearDown(settings.dispose);
      await settings.setSpeechProfiles([
        english,
        const SpeechProfile(
          id: 'de-1',
          name: 'Deutsch',
          language: 'de',
          modelDirectory: '/models/de',
          voicesDirectory: '/voices',
        ),
      ]);
      await settings.setSpeechDictionaries([
        const SpeechDictionary(
          id: 'names',
          name: 'Fantasy',
          language: 'en',
          entries: {'Ryo': 'Rio', 'Mage': 'Mayj'},
        ),
      ]);
      await settings.setSpeechPronunciations('novel', {'Ryo': 'Ree-oh'});
      expect(
        settings.speechProfileFor('novel', 'en')!.voicesDirectory,
        '/voices',
      );
      expect(settings.effectiveSpeechPronunciations('novel', english), {
        'Ryo': 'Ree-oh',
        'Mage': 'Mayj',
      });
      await settings.setSpeechDictionaryIds('novel', const []);
      expect(settings.effectiveSpeechPronunciations('novel', english), {
        'Ryo': 'Ree-oh',
      });
      await settings.setSpeechDictionaryIds('novel', ['names']);
      await settings.setSpeechProfileId('novel', 'de-1');
      expect(settings.speechProfileFor('novel', 'en')!.language, 'de');
      await settings.setSpeechProfileId('novel', null);
      expect(settings.speechProfileFor('novel', 'en')!.language, 'en');
      final restored = AppSettings.inMemory(
        values: {
          'speech_profiles': settings.speechProfiles
              .map((p) => p.toJson())
              .toList(),
          'speech_dictionaries': settings.speechDictionaries
              .map((d) => d.toJson())
              .toList(),
        },
      );
      addTearDown(restored.dispose);
      expect(restored.speechProfiles.first.voice, 'Alice');
      expect(restored.speechDictionaries.first.entries['Mage'], 'Mayj');
    },
  );
  test(
    'Sprach- und Stimmenwahl bleibt lokal nach Werk und Sprache getrennt',
    () async {
      final settings = AppSettings.inMemory();
      addTearDown(settings.dispose);

      await settings.setSpeechLanguageOverride('novel-en', 'en');
      await settings.setSpeechVoice('novel-en', 'en', 'english-female');
      await settings.setSpeechVoice('novel-en', 'de', 'german-default');
      await settings.setSpeechRate('novel-en', 1.35);
      await settings.setSpeechPronunciations('novel-en', const {'Ryo': 'Rio'});

      expect(settings.speechLanguageOverride('novel-en'), 'en');
      expect(settings.speechLanguageOverride('other-work'), isNull);
      expect(settings.speechVoice('novel-en', 'en'), 'english-female');
      expect(settings.speechVoice('novel-en', 'de'), 'german-default');
      expect(settings.speechRate('novel-en'), 1.35);
      expect(settings.speechRate('other-work'), 1);
      expect(settings.speechPronunciations('novel-en'), {'Ryo': 'Rio'});
      expect(settings.speechPronunciations('other-work'), isEmpty);

      await settings.setSpeechLanguageOverride('novel-en', null);
      expect(settings.speechLanguageOverride('novel-en'), isNull);
      expect(() => settings.setSpeechRate('novel-en', 3), throwsArgumentError);
    },
  );
  test(
    'übernimmt persönliche Vorlese-Einstellungen von einem anderen Werk',
    () async {
      final settings = AppSettings.inMemory();
      addTearDown(settings.dispose);
      await settings.setSpeechProfiles(const [
        SpeechProfile(
          id: 'english',
          name: 'English',
          language: 'en',
          modelDirectory: '/models/en',
          maxCharacters: 640,
          sentencePauseMs: 100,
          paragraphPauseMs: 700,
          chapterPauseMs: 1400,
          textRules: ['quotes'],
        ),
      ]);
      await settings.setSpeechProfileId('source', 'english');
      await settings.setSpeechLanguageOverride('source', 'en');
      await settings.setSpeechVoice('source', 'en', 'Harper');
      await settings.setSpeechRate('source', 1.4);
      await settings.setSpeechPronunciations('source', {'Ryo': 'Rio'});
      await settings.setSpeechDictionaryIds('source', ['fantasy']);

      await settings.copySpeechSettings('source', 'target');

      expect(settings.speechProfileId('target'), 'english');
      expect(settings.speechLanguageOverride('target'), 'en');
      expect(settings.speechVoice('target', 'en'), 'Harper');
      expect(settings.speechRate('target'), 1.4);
      expect(settings.speechPronunciations('target'), {'Ryo': 'Rio'});
      expect(settings.speechDictionaryIdsFor('target', null), ['fantasy']);
      expect(settings.speechProfiles.single.maxCharacters, 640);
      expect(settings.speechProfiles.single.textRules, ['quotes']);
    },
  );

  test(
    'werk kann Einstellungswörterbuch ohne Sprachprofil verwenden',
    () async {
      final settings = AppSettings.inMemory();
      addTearDown(settings.dispose);
      await settings.setSpeechDictionaries(const [
        SpeechDictionary(
          id: 'english',
          name: 'English names',
          language: 'en',
          entries: {'Ryo': 'Rio'},
        ),
      ]);
      await settings.setSpeechDictionaryIds('novel', ['english']);
      expect(
        settings.effectiveSpeechPronunciations('novel', null, language: 'en'),
        {'Ryo': 'Rio'},
      );
    },
  );
}
