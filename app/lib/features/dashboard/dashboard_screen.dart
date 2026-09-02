import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';
import '../library/work_cover.dart';

/// The daily entry point: continue first, everything else after.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final works = scope.library.works;

    final continuing =
        works
            .where((work) => work.hasProgress && !work.finished)
            .toList(growable: false)
          ..sort(
            (a, b) => (b.summary.lastListenedAt ?? b.summary.addedAt).compareTo(
              a.summary.lastListenedAt ?? a.summary.addedAt,
            ),
          );
    final recent = works.toList(growable: false)
      ..sort((a, b) => b.summary.addedAt.compareTo(a.summary.addedAt));

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        _Greeting(workCount: works.length),
        if (scope.library.isScanning || scope.library.scanProgress != null)
          const _ScanBanner(),
        const SizedBox(height: FundusSpace.x8),
        if (continuing.isNotEmpty) ...[
          const _SectionHeading(
            'Fortsetzen',
            hint: 'geräteübergreifend synchronisiert',
          ),
          _WorkStrip(works: continuing.take(8).toList()),
          const SizedBox(height: FundusSpace.x10),
        ],
        const _SectionHeading('Zuletzt hinzugefügt'),
        if (recent.isEmpty)
          FundusEmptyState(
            title: 'Diese Bibliothek ist noch leer',
            reason:
                'Es wurde noch nicht gescannt. Der Scan liest den Ordner ein '
                'und läuft im Hintergrund weiter.',
            action: FilledButton(
              onPressed: scope.library.isScanning ? null : scope.library.scan,
              child: const Text('Jetzt scannen'),
            ),
          )
        else
          _WorkStrip(works: recent.take(12).toList()),
      ],
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.workCount});

  final int workCount;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final hour = DateTime.now().hour;
    final greeting = hour < 11
        ? 'Guten Morgen'
        : hour < 18
        ? 'Guten Tag'
        : 'Guten Abend';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(greeting, style: Theme.of(context).textTheme.displayMedium),
              const SizedBox(height: FundusSpace.x2),
              Text(
                '${scope.library.displayName} · $workCount Werke',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: scope.library.isScanning
              ? scope.library.cancelScan
              : scope.library.scan,
          icon: Icon(
            scope.library.isScanning ? FundusIcons.close : FundusIcons.sync,
            size: FundusIcons.sizeSm,
          ),
          label: Text(scope.library.isScanning ? 'Scan abbrechen' : 'Scannen'),
        ),
      ],
    );
  }
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final progress = scope.library.scanProgress;
    if (progress == null) return const SizedBox.shrink();

    final phase = switch (progress.phase) {
      LibraryIndexPhase.scanning => 'Dateien werden gelesen',
      LibraryIndexPhase.importing => 'Werke werden zugeordnet',
      LibraryIndexPhase.completed => 'Scan abgeschlossen',
      LibraryIndexPhase.cancelled => 'Scan abgebrochen',
    };

    return Container(
      margin: const EdgeInsets.only(top: FundusSpace.x6),
      padding: const EdgeInsets.all(FundusSpace.x4),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: FundusRadius.mdAll,
        border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$phase · ${progress.fileCount} Dateien · '
                  '${progress.workCount} Werke',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (progress.currentPath != null)
                Flexible(
                  child: Text(
                    progress.currentPath!,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                  ),
                ),
            ],
          ),
          const SizedBox(height: FundusSpace.x3),
          // Without a total the scan cannot honestly show a percentage.
          const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title, {this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if (hint != null) ...[
            const SizedBox(width: FundusSpace.x3),
            Text(
              hint!,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _WorkStrip extends StatelessWidget {
  const _WorkStrip({required this.works});

  final List<WorkView> works;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;

    return SizedBox(
      height: 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: works.length,
        separatorBuilder: (_, _) => SizedBox(width: tokens.density.gap),
        itemBuilder: (context, index) {
          final work = works[index];
          return SizedBox(
            width: 150,
            child: InkWell(
              onTap: () => scope.navigation.go(WorkRoute(work.id)),
              borderRadius: FundusRadius.mdAll,
              hoverColor: tokens.hover,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: WorkCover(work: work)),
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    work.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    work.progressLabel ?? work.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
