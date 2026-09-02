import 'package:flutter/material.dart';

import '../theme/fundus_tokens.dart';
import '../tokens/fundus_icons.dart';
import '../tokens/fundus_metrics.dart';

/// An empty state that names its cause.
///
/// "Keine Treffer" without saying which filter caused it is a dead end, so
/// [reason] is required — it is the whole reason this component exists.
class FundusEmptyState extends StatelessWidget {
  const FundusEmptyState({
    super.key,
    required this.title,
    required this.reason,
    this.icon,
    this.action,
  });

  final String title;
  final String reason;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon ?? FundusIcons.empty, size: 34, color: tokens.textFaint),
            const SizedBox(height: FundusSpace.x6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: FundusSpace.x3),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.textMuted,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: FundusSpace.x8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
