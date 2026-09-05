import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';

/// How tall a poster and its caption are at a given width.
///
/// A fixed aspect ratio cannot hold this: the picture grows with the column,
/// the two lines of text under it do not, and the ratio that fits a desktop
/// column cuts the name off on a phone at 160 % system font. So the height is
/// measured — picture, gap, and room for the lines a caption can carry, at
/// whatever size the person set their type to.
double workPosterExtent({
  required double width,
  required TextScaler textScaler,
  bool withName = true,
}) {
  final picture = width * 3 / 2;
  if (!withName) return picture;
  const lineFactor = 1.35;
  final title = textScaler.scale(FundusType.base) * 1.25 * 2;
  final meta = textScaler.scale(FundusType.sm) * lineFactor;
  // Two pixels of slack. A line box is not exactly size × height — the font's
  // own ascent and descent round it up — and a caption that comes out one
  // pixel taller than its cell is a yellow overflow bar across the grid.
  return picture + FundusSpace.x3 + title + meta + 2;
}

/// A work as artwork, at a fixed width, with its name underneath.
///
/// The tile it replaces was a panel: padding around a picture, a border, text
/// in a box. What a library of films and series wants is the artwork itself —
/// edge to edge, cut to a round corner, with the interface stepping back.
/// Everything that has to be said over the picture is said in the two places
/// it is always said: origin at the top right, progress across the foot.
class WorkPoster extends StatefulWidget {
  const WorkPoster({
    super.key,
    required this.work,
    required this.onTap,
    required this.width,
    this.showName = true,
  });

  final WorkView work;
  final VoidCallback onTap;
  final double width;

  /// A rail names its works; a stage's row of thumbnails does not need to.
  final bool showName;

  @override
  State<WorkPoster> createState() => _WorkPosterState();
}

class _WorkPosterState extends State<WorkPoster> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final work = widget.work;

    return SizedBox(
      width: widget.width,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: _hovered ? 1.03 : 1,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: FundusArtwork.posterRadius,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: _hovered ? .5 : .3,
                        ),
                        blurRadius: _hovered ? 18 : 10,
                        offset: Offset(0, _hovered ? 8 : 4),
                      ),
                    ],
                  ),
                  child: WorkArtwork(work: work),
                ),
              ),
              if (widget.showName) ...[
                const SizedBox(height: FundusSpace.x3),
                Text(
                  work.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.25),
                ),
                if (work.subtitle.isNotEmpty)
                  Text(
                    work.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The picture itself, without a name or a hit target.
///
/// Split out from the poster because a stage, a detail header and a rail all
/// want the same picture with the same two marks on it, and only the rail
/// wants a caption.
class WorkArtwork extends StatelessWidget {
  const WorkArtwork({
    super.key,
    required this.work,
    this.aspectRatio = 2 / 3,
    this.borderRadius = FundusArtwork.posterRadius,
    this.showProgress = true,
    this.showOrigin = true,
  });

  final WorkView work;
  final double aspectRatio;
  final BorderRadius borderRadius;
  final bool showProgress;
  final bool showOrigin;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: aspectRatio,
    child: ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WorkImage(work: work),
          // A picture with white text over it needs a floor under the text.
          if (showProgress && work.hasProgress)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x66000000)],
                ),
              ),
            ),
          if (showOrigin)
            Positioned(
              top: FundusSpace.x2,
              right: FundusSpace.x2,
              child: _Chip(child: FundusOriginMark(work.origin)),
            ),
          if (showProgress && work.hasProgress)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: FundusProgressBar(
                fraction: work.progressFraction!,
                finished: work.finished,
                height: 3,
              ),
            ),
        ],
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .55),
      borderRadius: FundusRadius.smAll,
    ),
    child: Padding(padding: const EdgeInsets.all(3), child: child),
  );
}

/// The cover file, the veil over a protected work, or a stand-in ground.
class WorkImage extends StatelessWidget {
  const WorkImage({super.key, required this.work, this.blurred = false});

  final WorkView work;

  /// A stage uses the same picture twice: once sharp, once as the ground
  /// behind it. The blurred copy has no marks and no detail to read.
  final bool blurred;

  static const _grounds = <List<Color>>[
    [Color(0xff4b3f86), Color(0xff221f3c), Color(0xff151726)],
    [Color(0xff2f4a6b), Color(0xff1b2436), Color(0xff141726)],
    [Color(0xff5a4470), Color(0xff251f38), Color(0xff151726)],
    [Color(0xff3a5560), Color(0xff1c2a30), Color(0xff141a20)],
    [Color(0xff6b4a52), Color(0xff2c1f28), Color(0xff171420)],
    [Color(0xff40477e), Color(0xff1e2138), Color(0xff141626)],
    [Color(0xff57506b), Color(0xff242235), Color(0xff15161f)],
    [Color(0xff2c5a5a), Color(0xff18302f), Color(0xff131b1e)],
    [Color(0xff7a5f42), Color(0xff33261c), Color(0xff1a1512)],
    [Color(0xff463f7d), Color(0xff1f1d36), Color(0xff131424)],
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final path = work.coverPath;
    final file = path == null ? null : File(path);
    final picture = file != null && file.existsSync()
        ? Image.file(
            file,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, _, _) => _ground(context),
          )
        : _ground(context);

    if (blurred) {
      return ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: picture,
      );
    }
    if (!FundusScope.of(context).protection.veils(work)) return picture;
    return Stack(
      fit: StackFit.expand,
      children: [
        picture,
        // Veiled rather than removed: the work is still listed, and what the
        // protected shelf hides is the picture, not the fact.
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: ColoredBox(
              color: tokens.background.withValues(alpha: 0.35),
              child: Center(
                child: Icon(
                  FundusIcons.protected,
                  size: FundusIcons.sizeLg,
                  color: tokens.textFaint,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _ground(BuildContext context) {
    final tokens = context.fundus;
    final colors = _grounds[work.id.hashCode.abs() % _grounds.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0, 0.6, 1],
        ),
      ),
      child: blurred
          ? null
          : Center(
              child: Text(
                work.initials,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: tokens.neutral.s300,
                  letterSpacing: 1,
                ),
              ),
            ),
    );
  }
}
