import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../metadata/word_lookup.dart';

/// What a word means, from Wiktionary, under the text it was selected in.
Future<void> showWordLookupSheet(
  BuildContext context, {
  required String word,
  String? language,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => _WordLookupSheet(word: word, language: language),
);

class _WordLookupSheet extends StatefulWidget {
  const _WordLookupSheet({required this.word, this.language});

  final String word;
  final String? language;

  @override
  State<_WordLookupSheet> createState() => _WordLookupSheetState();
}

class _WordLookupSheetState extends State<_WordLookupSheet> {
  final _lookup = WordLookup();
  late final Future<WordDefinition?> _result = _lookup.lookup(
    widget.word,
    language: widget.language,
  );

  @override
  void dispose() {
    _lookup.close();
    super.dispose();
  }

  String get _word => WordLookup.clean(widget.word) ?? widget.word.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FundusSpace.x8,
          0,
          FundusSpace.x8,
          FundusSpace.x8,
        ),
        child: FutureBuilder<WordDefinition?>(
          future: _result,
          builder: (context, snapshot) {
            final definition = snapshot.data;
            final waiting = snapshot.connectionState != ConnectionState.done;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  definition?.word ?? _word,
                  style: theme.textTheme.headlineSmall,
                ),
                if (definition?.partOfSpeech case final kind?) ...[
                  const SizedBox(height: FundusSpace.x1),
                  Text(
                    kind,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.accent,
                    ),
                  ),
                ],
                const SizedBox(height: FundusSpace.x4),
                if (waiting)
                  const LinearProgressIndicator()
                else if (definition == null)
                  Text(
                    'Wiktionary kennt „$_word“ nicht, oder es ist gerade '
                    'nicht erreichbar.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (index, meaning)
                              in definition.meanings.indexed)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: FundusSpace.x2,
                              ),
                              child: Text(
                                '${index + 1}. $meaning',
                                style: theme.textTheme.bodyLarge,
                              ),
                            ),
                          const SizedBox(height: FundusSpace.x2),
                          Text(
                            'Aus Wiktionary, CC BY-SA 4.0',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: tokens.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: FundusSpace.x4),
                Wrap(
                  spacing: FundusSpace.x3,
                  runSpacing: FundusSpace.x2,
                  children: [
                    OutlinedButton(
                      onPressed: () => launchUrl(
                        definition?.source ??
                            Uri.https('de.wiktionary.org', '/w/index.php', {
                              'search': _word,
                            }),
                      ),
                      child: const Text('Bei Wiktionary'),
                    ),
                    OutlinedButton(
                      onPressed: () => launchUrl(
                        Uri.parse(
                          'https://www.deepl.com/translator#auto/de/'
                          '${Uri.encodeComponent(_word)}',
                        ),
                      ),
                      child: const Text('Übersetzen'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _word));
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: const Text('Kopieren'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
