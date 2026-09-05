import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import 'work_poster.dart';

/// One work, made large: the thing a library puts in front of you.
///
/// Its own artwork is the ground — blown up, blurred and faded into the page
/// — so the picture has no edge and the words have something dark enough to
/// sit on. A phone gets a shape close to a poster, because a cinematic band
/// on a 360-wide screen is a stripe; wider screens get the poster standing
/// beside the text, the way a shelf shows a spine.
class WorkSpotlight extends StatelessWidget {
  const WorkSpotlight({
    super.key,
    required this.work,
    required this.stage,
    required this.onOpen,
    required this.onDetails,
    this.onReroll,
    this.height,
    this.kicker = 'Vorschlag für heute',
  });

  final WorkView work;
  final FundusStageSize stage;
  final VoidCallback onOpen;
  final VoidCallback onDetails;

  /// Null where there is nothing to draw again — a shelf with one work.
  final VoidCallback? onReroll;

  /// Overrides the shape, for two spotlights standing side by side.
  final double? height;

  /// What the kicker over the title says.
  final String kicker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final width = MediaQuery.sizeOf(context).width;
    final height =
        this.height ?? min(width / stage.heroRatio, stage.heroMaxHeight);
    final summary = work.summary;
    final meta = [
      if (summary.publishedYear != null) '${summary.publishedYear}',
      ...summary.genres.take(2),
      work.origin.label,
    ].join(' · ');

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A backdrop fills the frame and is shown as it is; without one
          // the work's own cover stands in, blown up and blurred, so the
          // picture has no edge and the text has a ground dark enough to sit
          // on.
          WorkImage(work: work, wide: true, blurred: work.backdropPath == null),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x55000000)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tokens.background.withValues(alpha: .1),
                  tokens.background.withValues(alpha: .75),
                  tokens.background,
                ],
                stops: const [0, .62, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              stage.gutter,
              FundusSpace.x6,
              stage.gutter,
              FundusSpace.x6,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // On a wide screen the poster stands beside the text, the way
                // a shelf shows a spine. A phone has no room for both.
                if (stage != FundusStageSize.handset) ...[
                  SizedBox(
                    width: stage.posterWidth,
                    child: WorkArtwork(work: work, showOrigin: false),
                  ),
                  SizedBox(width: stage.gutter),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        kicker.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: tokens.accentRamp.s300,
                        ),
                      ),
                      const SizedBox(height: FundusSpace.x2),
                      Text(
                        work.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontSize: stage.titleSize,
                          height: 1.1,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: FundusSpace.x2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: tokens.textMuted,
                          ),
                        ),
                      ],
                      if (summary.description case final description?
                          when stage != FundusStageSize.handset) ...[
                        const SizedBox(height: FundusSpace.x3),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: Text(
                            description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: tokens.textMuted,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: FundusSpace.x4),
                      Wrap(
                        spacing: FundusSpace.x3,
                        runSpacing: FundusSpace.x2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: work.origin == FundusOrigin.unreachable
                                ? null
                                : onOpen,
                            icon: Icon(
                              FundusIcons.play,
                              size: FundusIcons.sizeSm,
                            ),
                            label: Text(
                              work.hasProgress ? 'Fortsetzen' : 'Abspielen',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: onDetails,
                            child: const Text('Details'),
                          ),
                          if (onReroll case final reroll?)
                            IconButton(
                              onPressed: reroll,
                              tooltip: 'Etwas anderes vorschlagen',
                              icon: Icon(
                                FundusIcons.shuffle,
                                size: FundusIcons.sizeMd,
                              ),
                            ),
                        ],
                      ),
                      if (work.progressLabel case final label?) ...[
                        const SizedBox(height: FundusSpace.x2),
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: tokens.accentRamp.s300,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
