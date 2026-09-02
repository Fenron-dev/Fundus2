import 'package:flutter/material.dart';

import '../theme/fundus_tokens.dart';
import '../tokens/fundus_metrics.dart';

enum FundusTagTone { accent, neutral, outline, success, warning, danger }

/// A small label tinted from the ramps. Tags carry meaning, never decoration.
class FundusTag extends StatelessWidget {
  const FundusTag(
    this.label, {
    super.key,
    this.tone = FundusTagTone.neutral,
    this.icon,
    this.onTap,
  });

  final String label;
  final FundusTagTone tone;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final (foreground, background) = switch (tone) {
      FundusTagTone.accent => (
        tokens.isDark ? tokens.accentRamp.s200 : tokens.accentRamp.s700,
        tokens.accentTint(0.14),
      ),
      FundusTagTone.neutral => (
        tokens.textMuted,
        tokens.text.withValues(alpha: 0.06),
      ),
      FundusTagTone.outline => (tokens.textMuted, Colors.transparent),
      FundusTagTone.success => (tokens.success, tokens.successGround),
      FundusTagTone.warning => (tokens.warning, tokens.warningGround),
      FundusTagTone.danger => (tokens.danger, tokens.dangerGround),
    };

    final content = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x3,
        vertical: FundusSpace.x1,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: FundusRadius.smAll,
        border: tone == FundusTagTone.outline
            ? Border.fromBorderSide(BorderSide(color: tokens.divider))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: FundusSpace.x1),
          ],
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: foreground),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: FundusRadius.smAll,
      child: content,
    );
  }
}
