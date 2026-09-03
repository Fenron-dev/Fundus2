import 'package:flutter/material.dart';

import '../theme/fundus_tokens.dart';
import '../tokens/fundus_metrics.dart';

/// Whether the other side is answering right now.
enum FundusConnectionState {
  /// Reached within the last few seconds.
  connected('Verbunden'),

  /// Paired, but silent — asleep, out of the network, or simply not in use.
  idle('Nicht verbunden'),

  /// Tried and refused: a wrong certificate, a revoked device, a closed port.
  refused('Abgewiesen');

  const FundusConnectionState(this.label);

  final String label;
}

/// A dot that says whether a device is reachable this second.
///
/// The same mark on both sides, because the question is the same one from
/// either end: the phone asking „does the Mac answer" and the Mac asking
/// „is the phone there" are one fact seen twice, and it would be confusing
/// for them to look different.
///
/// Deliberately not colour alone: a dot that only differs in hue says nothing
/// to a person who cannot tell green from grey, so the state is written next
/// to it wherever there is room, and carried as a tooltip where there is not.
class FundusConnectionDot extends StatelessWidget {
  const FundusConnectionDot({
    super.key,
    required this.state,
    this.label,
    this.showLabel = true,
  });

  final FundusConnectionState state;

  /// Overrides the state's own wording — „Seit 14:02" reads better than
  /// „Nicht verbunden" in a list of devices.
  final String? label;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final colour = switch (state) {
      FundusConnectionState.connected => tokens.success,
      FundusConnectionState.idle => tokens.textFaint,
      FundusConnectionState.refused => tokens.danger,
    };
    final text = label ?? state.label;

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        // A halo while it is live: the difference between a lit dot and a
        // grey one has to survive a glance in daylight.
        boxShadow: state == FundusConnectionState.connected
            ? [BoxShadow(color: colour.withValues(alpha: 0.5), blurRadius: 6)]
            : null,
      ),
    );

    if (!showLabel) return Tooltip(message: text, child: dot);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: FundusSpace.x2),
        Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: state == FundusConnectionState.connected
                ? tokens.success
                : tokens.textFaint,
          ),
        ),
      ],
    );
  }
}
