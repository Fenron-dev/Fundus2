import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/playback_controller.dart';
import '../library/work_poster.dart';
import 'player_screen.dart' show PlaybackRateButton;

/// The player strip below the content column.
///
/// It stays visible while anything is loaded — that is the point of a mini
/// player — and expands into the full player rather than opening a second one.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;
    final theme = Theme.of(context);
    final failure = player.failure;

    return Container(
      height: FundusShellMetrics.miniPlayerHeight,
      padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x4),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          SizedBox(width: 42, child: WorkArtwork(work: work, aspectRatio: 1)),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player.currentSource?.title ?? work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  failure ?? work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: failure == null ? tokens.textFaint : tokens.danger,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: player.previous,
            icon: Icon(FundusIcons.skipBack, size: FundusIcons.sizeMd),
            tooltip: 'Zurück',
          ),
          IconButton.filled(
            onPressed: player.playOrPause,
            icon: Icon(
              player.isPlaying ? FundusIcons.pause : FundusIcons.play,
              size: FundusIcons.sizeMd,
            ),
            tooltip: player.isPlaying ? 'Pause' : 'Wiedergabe',
          ),
          IconButton(
            onPressed: player.next,
            icon: Icon(FundusIcons.skipForward, size: FundusIcons.sizeMd),
            tooltip: 'Weiter',
          ),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            flex: 5,
            child: Row(
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
          ),
          const SizedBox(width: FundusSpace.x2),
          const PlaybackRateButton(compact: true),
          IconButton(
            onPressed: player.expand,
            icon: Icon(FundusIcons.expand, size: FundusIcons.sizeMd),
            tooltip: 'Player öffnen',
          ),
          IconButton(
            onPressed: player.close,
            icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
            tooltip: 'Schließen',
          ),
        ],
      ),
    );
  }
}

/// The mini player on a narrow window: one row, tap to expand.
class CompactPlayerBar extends StatelessWidget {
  const CompactPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final player = scope.player;
    final work = player.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;
    return InkWell(
      onTap: player.expand,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x3,
          vertical: FundusSpace.x2,
        ),
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border(top: BorderSide(color: tokens.divider)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 34,
                  child: WorkArtwork(work: work, aspectRatio: 1),
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Text(
                    player.currentSource?.title ?? work.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  onPressed: player.playOrPause,
                  icon: Icon(
                    player.isPlaying ? FundusIcons.pause : FundusIcons.play,
                    size: FundusIcons.sizeMd,
                  ),
                ),
              ],
            ),
            FundusProgressBar(fraction: player.progressFraction, height: 2),
          ],
        ),
      ),
    );
  }
}
