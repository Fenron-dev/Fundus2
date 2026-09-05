import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/download_controller.dart';

/// Downloads and offline copies.
///
/// Offline is a state of a work, not a separate holding: what is listed here
/// is the same catalogue, filtered to what is secured, with whatever is on
/// its way above it. Nothing here is a second kind of work — the entries lead
/// to the ordinary work screen.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final running = scope.downloads.jobs
        .where((job) => job.state != DownloadState.done)
        .toList(growable: false);
    final offline = scope.library.works
        .where((work) => work.origin == FundusOrigin.offline)
        .toList(growable: false);

    if (running.isEmpty && offline.isEmpty) {
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

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        if (running.isNotEmpty) ...[
          Text('UNTERWEGS', style: theme.textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          for (final job in running) _JobTile(job: job),
          const SizedBox(height: FundusSpace.x10),
        ],
        Text('AUF DIESEM GERÄT', style: theme.textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x3),
        if (offline.isEmpty)
          Text(
            'Noch nichts fertig gesichert.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          )
        else
          for (final work in offline)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: FundusOriginMark(work.origin),
              title: Text(work.title),
              subtitle: Text(work.subtitle),
              onTap: () => scope.navigation.go(WorkRoute(work.id)),
              trailing: IconButton(
                onPressed: () => scope.downloads.remove(work.id),
                icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
                tooltip: 'Kopie entfernen',
              ),
            ),
      ],
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

    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(job.title, style: theme.textTheme.bodyMedium),
              ),
              Text(
                switch (job.state) {
                  DownloadState.queued => 'wartet',
                  DownloadState.running =>
                    '${job.done}/${job.total} · '
                        '${(job.progress * 100).round()} %',
                  DownloadState.failed => 'fehlgeschlagen',
                  DownloadState.done => 'fertig',
                },
                style: theme.textTheme.labelMedium?.copyWith(
                  color: job.state == DownloadState.failed
                      ? tokens.danger
                      : tokens.textFaint,
                ),
              ),
              if (job.state == DownloadState.queued)
                IconButton(
                  onPressed: () => scope.downloads.cancel(job.workId),
                  icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
                  tooltip: 'Aus der Warteschlange nehmen',
                ),
            ],
          ),
          const SizedBox(height: FundusSpace.x2),
          LinearProgressIndicator(
            value: job.state == DownloadState.queued ? null : job.progress,
          ),
          if (job.failure case final failure?) ...[
            const SizedBox(height: FundusSpace.x2),
            Text(
              failure,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
