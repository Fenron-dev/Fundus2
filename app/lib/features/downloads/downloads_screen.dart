import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/download_controller.dart';
import '../../data/work_view.dart';

/// Downloads and offline copies.
///
/// Offline is a state of a work, not a separate holding: what is listed here
/// is the same catalogue, filtered to what is secured, with whatever is on
/// its way above it. Nothing here is a second kind of work — the entries lead
/// to the ordinary work screen.
///
/// What it adds to a plain list is the two things somebody comes here for:
/// how much of the device this is costing, and whether the thing they started
/// will be here before they leave.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final _selected = <String>{};
  bool _measured = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_measured) return;
    _measured = true;
    unawaited(FundusScope.of(context).downloads.measureStorage());
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final gutter = FundusStageSize.of(context).gutter;
    final running = scope.downloads.jobs
        .where((job) => job.state != DownloadState.done)
        .toList(growable: false);
    final offline = scope.library.works
        .where((work) => work.origin == FundusOrigin.offline)
        .toList(growable: false);
    final partial = scope.library.works
        .where(
          (work) =>
              work.origin != FundusOrigin.offline &&
              scope.downloads.hasOfflineFiles(work.id),
        )
        .toList(growable: false);
    final history = scope.downloads.jobs
        .where((job) => job.state == DownloadState.done)
        .toList(growable: false);

    if (running.isEmpty &&
        offline.isEmpty &&
        partial.isEmpty &&
        history.isEmpty) {
      return FundusEmptyState(
        title: 'Nichts heruntergeladen',
        reason: scope.peerLibraries.hasConnection
            ? 'Öffne ein Werk und wähle „Mitnehmen" — es liegt dann auch '
                  'ohne Netz hier.'
            : 'Werke eines gekoppelten Geräts lassen sich mitnehmen, solange '
                  'es erreichbar ist. Gerade antwortet keines.',
        icon: null,
      );
    }

    // Was ausgewählt ist, aber nicht mehr da: eine Auswahl darf nicht auf
    // Werke zeigen, die inzwischen gelöscht sind.
    _selected.removeWhere((id) => !offline.any((work) => work.id == id));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selected.isNotEmpty)
          _SelectionBar(
            count: _selected.length,
            onClear: () => setState(_selected.clear),
            onRemove: () async {
              final chosen = [..._selected];
              setState(_selected.clear);
              for (final id in chosen) {
                await scope.downloads.remove(id);
              }
            },
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              gutter,
              FundusSpace.x6,
              gutter,
              FundusSpace.x16,
            ),
            children: [
              _StorageCard(downloads: scope.downloads),
              if (running.isNotEmpty) ...[
                const SizedBox(height: FundusSpace.x8),
                Text('UNTERWEGS', style: theme.textTheme.labelSmall),
                const SizedBox(height: FundusSpace.x3),
                for (final job in running) _JobTile(job: job),
              ],
              const SizedBox(height: FundusSpace.x8),
              Text('AUF DIESEM GERÄT', style: theme.textTheme.labelSmall),
              const SizedBox(height: FundusSpace.x3),
              if (offline.isEmpty)
                Text(
                  'Noch nichts fertig gesichert.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textFaint,
                  ),
                )
              else
                for (final work in offline)
                  _OfflineTile(
                    work: work,
                    selected: _selected.contains(work.id),
                    selecting: _selected.isNotEmpty,
                    onSelect: () => setState(() {
                      if (!_selected.remove(work.id)) _selected.add(work.id);
                    }),
                    onOpen: () => scope.navigation.go(WorkRoute(work.id)),
                  ),
              if (partial.isNotEmpty) ...[
                const SizedBox(height: FundusSpace.x8),
                Text(
                  'TEILWEISE AUF DIESEM GERÄT',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: FundusSpace.x3),
                for (final work in partial)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: FundusOriginMark(work.origin),
                    title: Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${scope.downloads.offlineFileCount(work.id)} Datei(en) gesichert · Download fortsetzen',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                    onTap: () => scope.navigation.go(WorkRoute(work.id)),
                  ),
              ],
              if (history.isNotEmpty) ...[
                const SizedBox(height: FundusSpace.x8),
                Text('ABGESCHLOSSEN', style: theme.textTheme.labelSmall),
                const SizedBox(height: FundusSpace.x3),
                for (final job in history)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(FundusIcons.check, color: tokens.success),
                    title: Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${job.total} Datei(en) vollständig gesichert',
                    ),
                    onTap: () => scope.navigation.go(WorkRoute(job.workId)),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// What the copies cost, and where it goes.
///
/// The device's total capacity is deliberately not claimed: Flutter cannot
/// ask for it without a plugin, and a made-up total under a real number is
/// worse than no total at all.
class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.downloads});

  final DownloadController downloads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final byType = downloads.storageByType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = downloads.storedBytes;

    return Container(
      padding: const EdgeInsets.all(FundusSpace.x6),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: FundusRadius.lgAll,
        border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(formatBytes(total), style: theme.textTheme.displaySmall),
              const SizedBox(width: FundusSpace.x2),
              Text(
                'auf diesem Gerät',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
            ],
          ),
          if (byType.isNotEmpty) ...[
            const SizedBox(height: FundusSpace.x4),
            ClipRRect(
              borderRadius: FundusRadius.smAll,
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    for (final entry in byType)
                      Expanded(
                        flex: entry.value,
                        child: ColoredBox(
                          color: tokens.accentRamp.step(
                            300 + (byType.indexOf(entry) % 4) * 100,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: FundusSpace.x3),
            Text(
              [
                for (final entry in byType)
                  '${entry.key} ${formatBytes(entry.value)}',
              ].join(' · '),
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The bar that appears once something is picked.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onClear,
    required this.onRemove,
  });

  final int count;
  final VoidCallback onClear;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      color: tokens.surfaceRaised,
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x4,
        vertical: FundusSpace.x2,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onClear,
            tooltip: 'Auswahl aufheben',
            icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
          ),
          const SizedBox(width: FundusSpace.x2),
          Expanded(
            child: Text(
              '$count ausgewählt',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          IconButton(
            onPressed: () => unawaited(onRemove()),
            tooltip: 'Kopien entfernen',
            icon: Icon(
              FundusIcons.delete,
              size: FundusIcons.sizeMd,
              color: tokens.danger,
            ),
          ),
        ],
      ),
    );
  }
}

/// One work that is here for good.
class _OfflineTile extends StatelessWidget {
  const _OfflineTile({
    required this.work,
    required this.selected,
    required this.selecting,
    required this.onSelect,
    required this.onOpen,
  });

  final WorkView work;
  final bool selected;
  final bool selecting;
  final VoidCallback onSelect;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      // Langes Drücken wählt aus, Tippen öffnet — solange nichts ausgewählt
      // ist. Danach wählt auch das Tippen, wie überall sonst.
      onTap: selecting ? onSelect : onOpen,
      onLongPress: onSelect,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onSelect())
          : FundusOriginMark(work.origin),
      title: Text(work.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        work.subtitle.isEmpty ? 'vollständig' : work.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
      ),
    );
  }
}

/// A work on its way here.
class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final line = [
      if (job.state == DownloadState.failed)
        job.failure ?? 'Abgebrochen'
      else if (job.state == DownloadState.queued)
        'wartet'
      else
        '${job.done} von ${job.total} Dateien',
      if (job.bytesPerSecond case final speed? when speed > 0)
        '${formatBytes(speed.round())}/s',
      if (job.remaining case final left?) 'noch ${formatDuration(left)}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (job.state == DownloadState.failed)
                TextButton(
                  onPressed: () {
                    final work = scope.library.workById(job.workId);
                    if (work != null) unawaited(scope.downloads.download(work));
                  },
                  child: const Text('Erneut'),
                )
              else
                IconButton(
                  onPressed: () => scope.downloads.cancel(job.workId),
                  tooltip: 'Aus der Schlange nehmen',
                  icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
                ),
            ],
          ),
          const SizedBox(height: FundusSpace.x2),
          FundusProgressBar(
            fraction: job.progress,
            finished: job.state == DownloadState.done,
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            '${(job.progress * 100).toStringAsFixed(1)} % · $line',
            style: theme.textTheme.labelMedium?.copyWith(
              color: job.state == DownloadState.failed
                  ? tokens.danger
                  : tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bytes as somebody reads them.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = value >= 100
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}

/// „noch 19 Min", „noch 1 Min".
String formatDuration(Duration value) {
  if (value.inHours > 0) return '${value.inHours} Std';
  if (value.inMinutes > 0) return '${value.inMinutes} Min';
  return '${value.inSeconds} s';
}
