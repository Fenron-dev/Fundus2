import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../data/protection.dart';
import 'settings_shell.dart';

/// How much time went into what, year by year.
///
/// Counted on this device only, from playback and reading. A protected work
/// is left out while the protection mode is on, here as everywhere else.
class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  int _year = DateTime.now().year;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    final theme = Theme.of(context);
    final tokens = context.fundus;
    if (vault == null) {
      return const SettingsPage(
        title: 'Statistik & Jahresrückblick',
        subtitle: 'Dafür muss eine Bibliothek geöffnet sein.',
        children: [],
      );
    }
    final protecting = scope.protection.mode != ProtectionMode.off;
    final excluded = protecting
        ? {
            for (final work in scope.library.works)
              if (work.summary.isHhh) work.id,
          }
        : const <String>{};
    final summary = vault.usageSummary(
      from: DateTime(_year),
      until: DateTime(_year + 1),
      excludedWorkIds: excluded,
    );
    final thisYear = DateTime.now().year;

    return SettingsPage(
      title: 'Statistik & Jahresrückblick',
      subtitle:
          'Gezählt wird auf diesem Gerät, während etwas läuft oder gelesen '
          'wird. Die Zahlen bleiben hier und werden nicht abgeglichen.',
      children: [
        Wrap(
          spacing: FundusSpace.x2,
          runSpacing: FundusSpace.x2,
          children: [
            for (var year = thisYear; year > thisYear - 5; year--)
              ChoiceChip(
                selected: year == _year,
                onSelected: (_) => setState(() => _year = year),
                label: Text('$year'),
              ),
          ],
        ),
        if (summary.totalSeconds == 0)
          SettingsCard(
            child: Text(
              _year == thisYear
                  ? 'Für $_year ist noch nichts erfasst. Fundus zählt ab '
                        'jetzt, wie lange du hörst, schaust und liest.'
                  : 'Für $_year ist auf diesem Gerät nichts erfasst.'
                        '${protecting ? ' Geschützte Werke sind ausgeblendet.' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
          )
        else ...[
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _year == thisYear ? 'Dein Jahr bisher' : 'Dein Jahr $_year',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: FundusSpace.x4),
                Wrap(
                  spacing: FundusSpace.x10,
                  runSpacing: FundusSpace.x4,
                  children: [
                    _Figure(
                      value: _duration(summary.totalSeconds),
                      label: 'gehört, geschaut und gelesen',
                    ),
                    _Figure(
                      value: '${summary.finishedWorks}',
                      label: summary.finishedWorks == 1
                          ? 'Werk beendet'
                          : 'Werke beendet',
                    ),
                    _Figure(
                      value: '${summary.activeDays.length}',
                      label: 'Tage mit Fundus',
                    ),
                    _Figure(
                      value: '${summary.longestStreak}',
                      label: 'Tage am Stück, längste Serie',
                    ),
                  ],
                ),
                if (protecting) ...[
                  const SizedBox(height: FundusSpace.x4),
                  Text(
                    'Geschützte Werke sind ausgeblendet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Über das Jahr', style: theme.textTheme.titleMedium),
                const SizedBox(height: FundusSpace.x4),
                _MonthBars(seconds: summary.secondsByMonth),
              ],
            ),
          ),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nach Medienart', style: theme.textTheme.titleMedium),
                const SizedBox(height: FundusSpace.x3),
                for (final entry
                    in (summary.secondsByKind.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value))))
                  _Share(
                    label: _kindLabel(entry.key),
                    value: _duration(entry.value),
                    fraction: entry.value / summary.totalSeconds,
                  ),
              ],
            ),
          ),
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Am meisten Zeit', style: theme.textTheme.titleMedium),
                const SizedBox(height: FundusSpace.x3),
                for (final (index, work) in summary.topWorks.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Text(
                      '${index + 1}.',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: tokens.accent,
                      ),
                    ),
                    title: Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_kindLabel(work.kind)),
                    trailing: Text(_duration(work.seconds)),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _duration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours == 0) return '$minutes Min.';
    return minutes == 0 ? '$hours Std.' : '$hours Std. $minutes Min.';
  }

  static String _kindLabel(String kind) => switch (kind) {
    'audiobook' => 'Hörbücher',
    'podcast' => 'Podcasts',
    'album' || 'music' => 'Musik',
    'movie' => 'Filme',
    'tv' || 'series' => 'Serien',
    'anime' => 'Anime',
    'ebook' || 'book' || 'novel' || 'light_novel' => 'Bücher',
    'webnovel' => 'Webnovels',
    'manga' => 'Manga',
    'comic' => 'Comics',
    'document' => 'Dokumente',
    '' => 'Sonstiges',
    _ => kind,
  };
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: theme.textTheme.headlineSmall),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: context.fundus.textMuted,
          ),
        ),
      ],
    );
  }
}

class _Share extends StatelessWidget {
  const _Share({
    required this.label,
    required this.value,
    required this.fraction,
  });

  final String label;
  final String value;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(value, style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: FundusSpace.x1),
          ClipRRect(
            borderRadius: FundusRadius.smAll,
            child: LinearProgressIndicator(
              value: fraction.clamp(0, 1),
              minHeight: FundusChartMetrics.shareBarHeight,
            ),
          ),
        ],
      ),
    );
  }
}

/// Twelve bars, January to December.
class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.seconds});

  final Map<int, int> seconds;

  static const _letters = [
    'J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D', //
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final most = seconds.values.fold(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: FundusChartMetrics.monthBarsHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var month = 1; month <= 12; month++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: most == 0
                              ? 0
                              : (seconds[month] ?? 0) / most,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              borderRadius: FundusRadius.smAll,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: FundusSpace.x1),
                    Text(
                      _letters[month - 1],
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
