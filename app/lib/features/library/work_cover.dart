import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';

/// The stand-in grounds the prototype uses where a work has no cover yet.
/// They are deliberately desaturated and dark-ended so a grid of them still
/// reads as one surface rather than as confetti.
const _gradients = <List<Color>>[
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

/// A work's cover, with the origin mark in its top right corner and the
/// progress bar across its foot — always in those two places, on every screen.
class WorkCover extends StatelessWidget {
  const WorkCover({
    super.key,
    required this.work,
    this.aspectRatio = 2 / 3,
    this.showProgress = true,
    this.showOrigin = true,
  });

  final WorkView work;
  final double aspectRatio;
  final bool showProgress;
  final bool showOrigin;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final path = work.coverPath;
    final file = path == null ? null : File(path);

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: FundusRadius.mdAll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (file != null && file.existsSync())
              Image.file(file, fit: BoxFit.cover, errorBuilder: _fallback)
            else
              _placeholder(context),
            // Veiled rather than removed: the work is still listed, and what
            // the protected shelf hides is the picture, not the fact.
            if (FundusScope.of(context).protection.veils(work))
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
            if (showOrigin)
              Positioned(
                top: FundusSpace.x2,
                right: FundusSpace.x2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.background.withValues(alpha: 0.65),
                    borderRadius: FundusRadius.smAll,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: FundusOriginMark(work.origin),
                  ),
                ),
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

  Widget _fallback(BuildContext context, Object error, StackTrace? stack) =>
      _placeholder(context);

  Widget _placeholder(BuildContext context) {
    final tokens = context.fundus;
    final colors = _gradients[work.id.hashCode.abs() % _gradients.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0, 0.6, 1],
        ),
      ),
      child: Center(
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
