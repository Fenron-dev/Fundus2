import 'package:flutter/material.dart';

import '../theme/fundus_tokens.dart';
import '../tokens/fundus_metrics.dart';

/// How far through a work the reader or listener is.
///
/// Progress means something different per media type — seconds in a chapter,
/// page within a volume, a fraction of an EPUB chapter, the page a PDF was
/// last left on — so this component takes an already-resolved [fraction] and a
/// human [label]; it never derives one from the other.
class FundusProgressBar extends StatelessWidget {
  const FundusProgressBar({
    super.key,
    required this.fraction,
    this.height = 4,
    this.finished = false,
  });

  /// 0.0 – 1.0. Values outside are clamped rather than rejected: a sidecar
  /// written by another device is data, not a contract.
  final double fraction;
  final double height;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final value = fraction.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: LinearProgressIndicator(
          value: value,
          minHeight: height,
          backgroundColor: tokens.divider,
          valueColor: AlwaysStoppedAnimation(
            finished ? tokens.success : tokens.accent,
          ),
        ),
      ),
    );
  }
}

/// The progress bar with its label underneath, as used on tiles and rows.
class FundusProgress extends StatelessWidget {
  const FundusProgress({
    super.key,
    required this.fraction,
    this.label,
    this.finished = false,
  });

  final double fraction;
  final String? label;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final label = this.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FundusProgressBar(fraction: fraction, finished: finished),
        if (label != null) ...[
          const SizedBox(height: FundusSpace.x2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: tokens.textMuted),
          ),
        ],
      ],
    );
  }
}
