import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/playback_controller.dart';
import '../library/work_cover.dart';

/// The full player, laid over the shell.
///
/// Secondary material — tracks and chapters — sits beside the transport rather
/// than under it, so nothing has to slide up from the bottom edge where the
/// system gestures live.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;
    final isCompact =
        MediaQuery.sizeOf(context).width < FundusShellMetrics.compactBreakpoint;

    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FundusSpace.x4,
                vertical: FundusSpace.x2,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: player.collapse,
                    icon: Icon(FundusIcons.collapse, size: FundusIcons.sizeLg),
                    tooltip: 'Minimieren',
                  ),
                  const Spacer(),
                  FundusOriginMark(work.origin, showLabel: true),
                ],
              ),
            ),
            Expanded(
              child: isCompact
                  ? _Transport(compact: true)
                  : Row(
                      children: [
                        const Expanded(flex: 3, child: _Transport()),
                        SizedBox(
                          width: 320,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: tokens.divider),
                              ),
                            ),
                            child: const _ContextPanel(),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work!;
    final tokens = context.fundus;
    final theme = Theme.of(context);

    // A film shows its picture where an audiobook shows its cover.
    final video = player.videoSurface();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      child: Column(
        children: [
          if (video != null)
            ClipRRect(
              borderRadius: FundusRadius.mdAll,
              child: AspectRatio(aspectRatio: 16 / 9, child: video),
            )
          else
            SizedBox(
              width: compact ? 220 : 260,
              child: WorkCover(work: work, showProgress: false),
            ),
          const SizedBox(height: FundusSpace.x8),
          Text(
            work.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.displayMedium,
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            player.currentSource?.title ?? work.subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x8),
          Row(
            children: [
              Text(
                formatPlaybackTime(player.position),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
              Expanded(
                child: Slider(
                  value: player.progressFraction,
                  onChanged: (value) {
                    final total = player.duration;
                    if (total == null) return;
                    player.seek(total * value);
                  },
                ),
              ),
              Text(
                player.duration == null
                    ? '--:--'
                    : formatPlaybackTime(player.duration!),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ],
          ),
          const SizedBox(height: FundusSpace.x4),
          Wrap(
            spacing: FundusSpace.x3,
            runSpacing: FundusSpace.x3,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed: () =>
                    player.seekRelative(const Duration(seconds: -15)),
                child: const Text('−15 s'),
              ),
              IconButton(
                onPressed: player.previous,
                icon: Icon(FundusIcons.skipBack, size: FundusIcons.sizeLg),
                tooltip: 'Vorheriger Titel',
              ),
              IconButton.filled(
                onPressed: player.playOrPause,
                iconSize: FundusIcons.sizeLg,
                icon: Icon(
                  player.isPlaying ? FundusIcons.pause : FundusIcons.play,
                ),
                tooltip: player.isPlaying ? 'Pause' : 'Wiedergabe',
              ),
              IconButton(
                onPressed: player.next,
                icon: Icon(FundusIcons.skipForward, size: FundusIcons.sizeLg),
                tooltip: 'Nächster Titel',
              ),
              TextButton(
                onPressed: () =>
                    player.seekRelative(const Duration(seconds: 30)),
                child: const Text('+30 s'),
              ),
              OutlinedButton(
                onPressed: player.cycleRate,
                child: Text('${player.rate}×'),
              ),
            ],
          ),
          if (compact) ...[
            const SizedBox(height: FundusSpace.x8),
            const _ContextPanel(shrinkWrap: true),
          ],
        ],
      ),
    );
  }
}

class _ContextPanel extends StatelessWidget {
  const _ContextPanel({this.shrinkWrap = false});

  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final tokens = context.fundus;
    final chapters = player.chapters;
    final tracks = player.sources;
    // Chapters only when they really are marks inside a file. A work made of
    // several files also yields one "chapter" per file, all sitting at
    // 00:00 — as a list of twelve episodes that is worse than useless, so
    // those are shown as what they are, with their length.
    final useChapters =
        chapters.length > 1 &&
        chapters.any((chapter) => chapter.position > Duration.zero);
    final heading = useChapters
        ? 'KAPITEL'
        : player.showsVideo
        ? 'FOLGEN'
        : 'DATEIEN';

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(FundusSpace.x4),
      children: [
        Text(heading, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x3),
        if (useChapters)
          for (final chapter in chapters)
            _Entry(
              label: chapter.title,
              trailing: formatPlaybackTime(chapter.position),
              active:
                  chapter.fileId == player.currentSource?.fileId &&
                  chapter.position <= player.position,
              onTap: () => player.jumpToChapter(chapter),
            )
        else
          for (var index = 0; index < tracks.length; index++)
            _Entry(
              label: tracks[index].title,
              trailing: tracks[index].duration == null
                  ? null
                  : formatPlaybackTime(tracks[index].duration!),
              active: index == player.trackIndex,
              onTap: () => player.jumpToTrack(index),
            ),
        if (tracks.isEmpty && chapters.isEmpty)
          Text(
            'Keine Titelliste vorhanden.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.label,
    required this.active,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final String? trailing;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return InkWell(
      onTap: onTap,
      borderRadius: FundusRadius.mdAll,
      hoverColor: tokens.hover,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x3,
          vertical: FundusSpace.x2,
        ),
        decoration: BoxDecoration(
          color: active ? tokens.surfaceRaised : null,
          borderRadius: FundusRadius.mdAll,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: active ? tokens.accentRamp.s200 : tokens.text,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
              ),
          ],
        ),
      ),
    );
  }
}
