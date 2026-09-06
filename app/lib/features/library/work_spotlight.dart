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
          // Das Bild füllt die Fläche, statt klein in der Mitte zu stehen und
          // ringsum weichgezeichnet zu werden. Oben angesetzt, weil auf einem
          // Cover oben steht, was man erkennen will.
          FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: 1000,
              height: work.backdropPath == null ? 1500 : 563,
              child: WorkImage(work: work, wide: true),
            ),
          ),
          // Ein Boden für die Schrift, sonst nichts: je weiter unten, desto
          // dunkler, damit der Text steht und das Bild oben frei bleibt.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  tokens.background.withValues(alpha: .55),
                  tokens.background.withValues(alpha: .92),
                ],
                stops: const [.35, .68, 1],
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kicker.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: tokens.accentRamp.s300,
                  ),
                ),
                const SizedBox(height: FundusSpace.x2),
                _FittedTitle(
                  title: work.title,
                  style:
                      theme.textTheme.displayLarge?.copyWith(
                        height: 1.1,
                        letterSpacing: -0.5,
                      ) ??
                      const TextStyle(),
                  size: stage.titleSize,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    meta,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                ],
                if (summary.description case final description?
                    when stage == FundusStageSize.desktop) ...[
                  const SizedBox(height: FundusSpace.x3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Text(
                      description,
                      maxLines: 2,
                      textAlign: TextAlign.center,
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
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      // Auch hier gilt: der Versuch entscheidet, nicht die
                      // Markierung vom letzten Durchgang.
                      onPressed: onOpen,
                      icon: Icon(FundusIcons.play, size: FundusIcons.sizeSm),
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
                    textAlign: TextAlign.center,
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
    );
  }
}

/// A title that gets smaller rather than shorter.
///
/// „I Became an S-Rank Hunter …" says nothing; the whole name at two thirds
/// of the size says everything. So the size is chosen by measuring: the
/// largest that fits the width in at most three lines, down to a floor below
/// which it would stop being a headline.
class _FittedTitle extends StatelessWidget {
  const _FittedTitle({
    required this.title,
    required this.style,
    required this.size,
  });

  final String title;
  final TextStyle style;

  /// The size it would like to be.
  final double size;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Text(
      title,
      textAlign: TextAlign.center,
      maxLines: fittedTitleMaxLines,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(
        fontSize: fittedTitleSize(
          title: title,
          style: style,
          size: size,
          maxWidth: constraints.maxWidth,
          direction: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        ),
      ),
    ),
  );
}

/// How many lines a headline may take before it has to get smaller.
const fittedTitleMaxLines = 3;

/// The largest size at which [title] still fits in [maxWidth].
///
/// Measured rather than guessed: a name is either readable or it is not, and
/// „I Became an S-Rank Hunter …" is not. Below 55 % of the intended size it
/// stops being a headline, so there the shrinking stops and the ellipsis does
/// its job after all.
double fittedTitleSize({
  required String title,
  required TextStyle style,
  required double size,
  required double maxWidth,
  required TextDirection direction,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (maxWidth <= 0 || !maxWidth.isFinite) return size;
  final floor = size * 0.55;
  var chosen = size;
  while (chosen > floor) {
    final painter = TextPainter(
      text: TextSpan(
        text: title,
        style: style.copyWith(fontSize: chosen),
      ),
      textAlign: TextAlign.center,
      textDirection: direction,
      maxLines: fittedTitleMaxLines,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    if (fits) break;
    chosen -= 2;
  }
  return chosen;
}
