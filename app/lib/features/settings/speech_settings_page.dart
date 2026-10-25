import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/fundus_scope.dart';
import '../../media/speech_profile.dart';
import '../../media/phonon_model_store.dart';
import '../../media/phonon_voice_catalog.dart';
import '../../media/speech_text_rules.dart';
import '../reader/speech_model_status.dart';
import 'settings_shell.dart';

String speechLanguageLabel(String code) => switch (code) {
  'en' => 'English',
  'de' => 'Deutsch',
  'fr' => 'Französisch',
  'es' => 'Spanisch',
  'pt' => 'Portugiesisch',
  _ => code,
};

class SpeechSettingsPage extends StatelessWidget {
  const SpeechSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    return ListenableBuilder(
      listenable: scope.settings,
      builder: (context, _) {
        final settings = scope.settings;
        return SettingsPage(
          title: 'Vorlesen / TTS',
          subtitle:
              'Sprachprofile und Aussprachewörterbücher. Das Tempo wählst du direkt im Reader.',
          children: [
            if (Platform.isAndroid)
              const SettingsCard(child: SpeechModelStatus()),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sprach- und Stimmprofile',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: FundusSpace.x2),
                  const Text(
                    'Ein Profil verbindet Sprache, Modell und Stimme. Mehrere Profile können dieselben Ordner verwenden. Vorhandene Phonon-Stimmenordner mit voices.jsonl werden direkt gelesen, ohne Modelle oder Stimmen zu kopieren.',
                  ),
                  for (final profile in settings.speechProfiles)
                    ListTile(
                      title: Text(profile.name),
                      subtitle: Text(
                        '${speechLanguageLabel(profile.language)} · ${profile.voice ?? 'Modellstandard'}',
                      ),
                      onTap: () => editSpeechProfile(context, profile),
                      trailing: IconButton(
                        tooltip: 'Profil entfernen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => settings.setSpeechProfiles(
                          settings.speechProfiles
                              .where((p) => p.id != profile.id)
                              .toList(),
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => editSpeechProfile(context, null),
                    icon: const Icon(Icons.add),
                    label: const Text('Profil hinzufügen'),
                  ),
                ],
              ),
            ),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Aussprachewörterbücher',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Text(
                    'Zum Beispiel Englisch, Deutsch oder Fantasy-Namen. Im Profil wählst du die Wörterbücher aus. Werkbezogene Aussprachen haben Vorrang; der Buchtext bleibt unverändert.',
                  ),
                  for (final dictionary in settings.speechDictionaries)
                    ListTile(
                      title: Text(dictionary.name),
                      subtitle: Text(
                        '${dictionary.language == null ? 'Alle Sprachen' : speechLanguageLabel(dictionary.language!)} · ${dictionary.entries.length} Einträge',
                      ),
                      onTap: () => editSpeechDictionary(context, dictionary),
                      trailing: IconButton(
                        tooltip: 'Wörterbuch entfernen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => settings.setSpeechDictionaries(
                          settings.speechDictionaries
                              .where((d) => d.id != dictionary.id)
                              .toList(),
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => editSpeechDictionary(context, null),
                    icon: const Icon(Icons.add),
                    label: const Text('Wörterbuch hinzufügen'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> editSpeechProfile(
  BuildContext context,
  SpeechProfile? original,
) async {
  final scope = FundusScope.of(context);
  final name = TextEditingController(text: original?.name ?? '');
  var language = original?.language ?? 'en';
  String? directory =
      original?.modelDirectory ?? scope.settings.phononModelDirectory;
  String? voicesDirectory = original?.voicesDirectory;
  String? voice = original?.voice;
  var voices = <PhononVoiceInfo>[];
  var busy = false;
  String? error;
  final dictionaries = {...?original?.dictionaryIds};
  var maxCharacters = original?.maxCharacters ?? 400;
  var sentencePauseMs = original?.sentencePauseMs ?? 120;
  var paragraphPauseMs = original?.paragraphPauseMs ?? 600;
  var chapterPauseMs = original?.chapterPauseMs ?? 1500;
  final textRules = {...?original?.textRules};
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, update) {
        Future<void> loadVoices() async {
          if (directory == null || busy) return;
          if (scope.textSpeech.isActive) {
            update(
              () => error =
                  'Bitte das Vorlesen vor dem Laden eines anderen Modells beenden.',
            );
            return;
          }
          update(() {
            busy = true;
            error = null;
          });
          try {
            if (Platform.isMacOS) {
              await scope.vaultAccess.unlock(directory!);
              if (voicesDirectory != null) {
                await scope.vaultAccess.unlock(voicesDirectory!);
              }
            }
            final selectedLanguage = SpeechLanguageResolver.parse(language)!;
            final languages = await scope.textSpeech.availableLanguages(
              modelDirectory: directory!,
              language: selectedLanguage,
              voicesDirectory: voicesDirectory,
            );
            if (!languages.contains(selectedLanguage)) {
              throw StateError(
                'Das Modell unterstützt ${speechLanguageLabel(language)} nicht.',
              );
            }
            final available = await scope.textSpeech.availableVoices(
              modelDirectory: directory!,
              language: selectedLanguage,
              voicesDirectory: voicesDirectory,
            );
            final details = await PhononVoiceCatalog.readDetailed(
              voicesDirectory ?? directory,
            );
            final byName = {for (final item in details) item.name: item};
            final voiceOptions = [
              for (final name in available)
                byName[name] ?? PhononVoiceInfo(name: name, path: ''),
            ];
            if (dialogContext.mounted) {
              update(() {
                voices = voiceOptions;
                if (!voices.any((item) => item.name == voice)) voice = null;
              });
            }
          } on Object catch (e) {
            if (dialogContext.mounted) {
              update(
                () => error = e.toString().replaceFirst('Bad state: ', ''),
              );
            }
          } finally {
            if (dialogContext.mounted) update(() => busy = false);
          }
        }

        return AlertDialog(
          title: Text(
            original == null
                ? 'Sprachprofil erstellen'
                : 'Sprachprofil bearbeiten',
          ),
          content: SizedBox(
            width: FundusSpeechMetrics.dialogWidth,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Profilname, z. B. English · Erzählerin',
                    ),
                  ),
                  const SizedBox(height: FundusSpace.x3),
                  DropdownButtonFormField<String>(
                    initialValue: language,
                    decoration: const InputDecoration(labelText: 'Sprache'),
                    items: [
                      for (final lang in SpeechLanguage.values)
                        DropdownMenuItem(
                          value: SpeechLanguageResolver.code(lang),
                          child: Text(
                            speechLanguageLabel(
                              SpeechLanguageResolver.code(lang),
                            ),
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => update(() {
                            language = value!;
                            voices = [];
                            voice = null;
                          }),
                  ),
                  const SizedBox(height: FundusSpace.x3),
                  Text('Modell / Ausgabequalität'),
                  Text(
                    '${directory ?? 'Kein Modell gewählt'}\n'
                    'Die gewählte Modellvariante bestimmt derzeit Qualität und Geschwindigkeit. Seed und Variation (Temperatur) werden von der nativen Live-Engine noch nicht angeboten.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Wrap(
                    spacing: FundusSpace.x2,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                try {
                                  String? selected;
                                  if (Platform.isAndroid) {
                                    final picked = await FilePicker.pickFiles(
                                      type: FileType.custom,
                                      allowedExtensions: ['zip'],
                                    );
                                    final path =
                                        picked?.files.firstOrNull?.path;
                                    if (path != null) {
                                      selected =
                                          await PhononModelStore.importCpuModelArchive(
                                            archivePath: path,
                                            applicationSupportPath:
                                                (await getApplicationSupportDirectory())
                                                    .path,
                                          );
                                    }
                                  } else {
                                    selected =
                                        await FilePicker.getDirectoryPath(
                                          dialogTitle:
                                              'Phonon-Modellordner wählen',
                                        );
                                  }
                                  if (selected == null) return;
                                  await scope.vaultAccess.remember(selected);
                                  if (dialogContext.mounted) {
                                    update(() {
                                      directory = selected;
                                      voices = [];
                                      voice = null;
                                    });
                                  }
                                } on Object catch (e) {
                                  if (dialogContext.mounted) {
                                    update(() => error = '$e');
                                  }
                                }
                              },
                        icon: const Icon(Icons.folder_open),
                        label: Text(
                          Platform.isAndroid
                              ? 'Modell-ZIP importieren'
                              : 'Modellordner wählen',
                        ),
                      ),
                      if (Platform.isAndroid)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() => busy = true);
                                  final selected = await scope.speechModels
                                      .ensureAvailable(retry: true);
                                  if (dialogContext.mounted) {
                                    update(() {
                                      directory = selected ?? directory;
                                      busy = false;
                                      error = scope.speechModels.failure;
                                    });
                                  }
                                },
                          child: const Text('Vom Server beziehen'),
                        ),
                    ],
                  ),
                  const SizedBox(height: FundusSpace.x3),
                  Text(voicesDirectory ?? 'Stimmen aus dem Modellordner'),
                  if (!Platform.isAndroid)
                    Wrap(
                      spacing: FundusSpace.x2,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  final selected =
                                      await FilePicker.getDirectoryPath(
                                        dialogTitle:
                                            'Phonon-Stimmenordner mit voices.jsonl wählen',
                                      );
                                  if (selected == null) return;
                                  await scope.vaultAccess.remember(selected);
                                  if (dialogContext.mounted) {
                                    update(() {
                                      voicesDirectory = selected;
                                      voices = [];
                                      voice = null;
                                    });
                                  }
                                },
                          icon: const Icon(Icons.record_voice_over_outlined),
                          label: const Text('Separaten Stimmenordner wählen'),
                        ),
                        if (voicesDirectory != null)
                          TextButton(
                            onPressed: () => update(() {
                              voicesDirectory = null;
                              voices = [];
                              voice = null;
                            }),
                            child: const Text('Modellstimmen verwenden'),
                          ),
                      ],
                    ),
                  TextButton.icon(
                    onPressed: busy ? null : loadVoices,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      busy
                          ? 'Modell wird geprüft …'
                          : 'Sprachen und Stimmen laden',
                    ),
                  ),
                  if (voices.isNotEmpty)
                    DropdownButtonFormField<String>(
                      key: ValueKey(voices.map((v) => v.name).join('|')),
                      initialValue: voice,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Stimme'),
                      items: [
                        for (final entry in voices)
                          DropdownMenuItem(
                            value: entry.name,
                            child: Text(
                              entry.displayLabel,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => update(() => voice = value),
                    ),
                  const SizedBox(height: FundusSpace.x3),
                  Text(
                    'Sprachverarbeitung',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    'Längere Abschnitte klingen meist natürlicher. Die Textregeln ändern nur den gesprochenen Text, nie das Buch.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text('Maximale Zeichen pro Abschnitt: $maxCharacters'),
                  Slider(
                    value: maxCharacters.toDouble(),
                    min: 80,
                    max: 1000,
                    divisions: 92,
                    onChanged: (value) =>
                        update(() => maxCharacters = (value / 10).round() * 10),
                  ),
                  Text('Pause zwischen Abschnitten: $sentencePauseMs ms'),
                  Slider(
                    value: sentencePauseMs.toDouble(),
                    min: 0,
                    max: 1000,
                    divisions: 20,
                    onChanged: (value) => update(
                      () => sentencePauseMs = (value / 50).round() * 50,
                    ),
                  ),
                  Text('Pause nach Absatz: $paragraphPauseMs ms'),
                  Slider(
                    value: paragraphPauseMs.toDouble(),
                    min: 0,
                    max: 3000,
                    divisions: 30,
                    onChanged: (value) => update(
                      () => paragraphPauseMs = (value / 100).round() * 100,
                    ),
                  ),
                  Text('Pause nach Kapitel: $chapterPauseMs ms'),
                  Slider(
                    value: chapterPauseMs.toDouble(),
                    min: 0,
                    max: 5000,
                    divisions: 50,
                    onChanged: (value) => update(
                      () => chapterPauseMs = (value / 100).round() * 100,
                    ),
                  ),
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    'Textregeln für ${speechLanguageLabel(language)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  for (final rule in SpeechTextRules.forLanguage(language))
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(rule.title),
                      subtitle: Text(rule.description),
                      value: textRules.contains(rule.id),
                      onChanged: (enabled) => update(() {
                        if (enabled == true) {
                          textRules.add(rule.id);
                        } else {
                          textRules.remove(rule.id);
                        }
                      }),
                    ),
                  TextButton.icon(
                    onPressed:
                        busy || directory == null || scope.textSpeech.isActive
                        ? null
                        : () async {
                            update(() {
                              busy = true;
                              error = null;
                            });
                            await scope.textSpeech.preview(
                              modelDirectory: directory!,
                              language: SpeechLanguageResolver.parse(language)!,
                              voicesDirectory: voicesDirectory,
                              voice: voice,
                              rules: textRules,
                            );
                            if (dialogContext.mounted) {
                              update(() {
                                busy = false;
                                error = scope.textSpeech.failure;
                              });
                            }
                          },
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('Stimme probehören'),
                  ),
                  const SizedBox(height: FundusSpace.x3),
                  const Text('Wörterbücher für dieses Profil'),
                  for (final dictionary
                      in scope.settings.speechDictionaries.where(
                        (d) => d.language == null || d.language == language,
                      ))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(dictionary.name),
                      value: dictionaries.contains(dictionary.id),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          dictionaries.add(dictionary.id);
                        } else {
                          dictionaries.remove(dictionary.id);
                        }
                      }),
                    ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty || directory == null) {
                        update(
                          () => error =
                              'Bitte Profilname und Modellordner angeben.',
                        );
                        return;
                      }
                      final profile = SpeechProfile(
                        id:
                            original?.id ??
                            'speech-${DateTime.now().microsecondsSinceEpoch}',
                        name: name.text.trim(),
                        language: language,
                        modelDirectory: directory!,
                        voicesDirectory: voicesDirectory,
                        voice: voice,
                        dictionaryIds: dictionaries.toList(),
                        maxCharacters: maxCharacters,
                        sentencePauseMs: sentencePauseMs,
                        paragraphPauseMs: paragraphPauseMs,
                        chapterPauseMs: chapterPauseMs,
                        textRules: textRules.toList(),
                      );
                      await scope.settings.setSpeechProfiles([
                        for (final value in scope.settings.speechProfiles)
                          value.id == profile.id ? profile : value,
                        if (!scope.settings.speechProfiles.any(
                          (p) => p.id == profile.id,
                        ))
                          profile,
                      ]);
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                    },
              child: const Text('Speichern'),
            ),
          ],
        );
      },
    ),
  );
  name.dispose();
}

Future<MapEntry<String, String>?> editSpeechPronunciation(
  BuildContext context, {
  String? source,
  String? spoken,
}) async {
  final word = TextEditingController(text: source);
  final replacement = TextEditingController(text: spoken);
  final result = await showDialog<MapEntry<String, String>>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Aussprache'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: word,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Wort im Buch'),
          ),
          const SizedBox(height: FundusSpace.x2),
          TextField(
            controller: replacement,
            decoration: const InputDecoration(labelText: 'So aussprechen'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            if (word.text.trim().isNotEmpty &&
                replacement.text.trim().isNotEmpty) {
              Navigator.pop(
                dialog,
                MapEntry(word.text.trim(), replacement.text.trim()),
              );
            }
          },
          child: const Text('Speichern'),
        ),
      ],
    ),
  );
  word.dispose();
  replacement.dispose();
  return result;
}

Future<void> editSpeechDictionary(
  BuildContext context,
  SpeechDictionary? original,
) async {
  final settings = FundusScope.of(context).settings;
  final name = TextEditingController(text: original?.name);
  var language = original?.language ?? '';
  final entries = {...?original?.entries};
  await showDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, update) => AlertDialog(
        title: const Text('Aussprachewörterbuch'),
        content: SizedBox(
          width: FundusSpeechMetrics.dialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: FundusSpace.x2),
                DropdownButtonFormField<String>(
                  initialValue: language,
                  decoration: const InputDecoration(labelText: 'Sprache'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Alle Sprachen'),
                    ),
                    for (final lang in SpeechLanguage.values)
                      DropdownMenuItem(
                        value: SpeechLanguageResolver.code(lang),
                        child: Text(
                          speechLanguageLabel(
                            SpeechLanguageResolver.code(lang),
                          ),
                        ),
                      ),
                  ],
                  onChanged: (value) => update(() => language = value!),
                ),
                for (final entry in entries.entries.toList())
                  ListTile(
                    title: Text(entry.key),
                    subtitle: Text(entry.value),
                    onTap: () async {
                      final changed = await editSpeechPronunciation(
                        dialog,
                        source: entry.key,
                        spoken: entry.value,
                      );
                      if (changed != null && dialog.mounted) {
                        update(() {
                          entries.remove(entry.key);
                          entries[changed.key] = changed.value;
                        });
                      }
                    },
                    trailing: IconButton(
                      tooltip: 'Eintrag entfernen',
                      onPressed: () => update(() => entries.remove(entry.key)),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () async {
                    final added = await editSpeechPronunciation(dialog);
                    if (added != null && dialog.mounted) {
                      update(() => entries[added.key] = added.value);
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Wort hinzufügen'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              final dictionary = SpeechDictionary(
                id:
                    original?.id ??
                    'dictionary-${DateTime.now().microsecondsSinceEpoch}',
                name: name.text.trim(),
                language: language.isEmpty ? null : language,
                entries: entries,
              );
              await settings.setSpeechDictionaries([
                for (final value in settings.speechDictionaries)
                  value.id == dictionary.id ? dictionary : value,
                if (!settings.speechDictionaries.any(
                  (d) => d.id == dictionary.id,
                ))
                  dictionary,
              ]);
              if (dialog.mounted) Navigator.pop(dialog);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
}
