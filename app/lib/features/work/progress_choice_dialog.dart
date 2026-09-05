import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';

/// „Wo willst du weitermachen?"
///
/// Asked at the one moment it is a real question — when the work is being
/// opened — and never during a sync, which happens to works nobody is
/// thinking about. Both sides are named by the device they come from and
/// shown in the terms the work is measured in, because „hier 20 min, dort
/// 40 min" is something a person can weigh up and `2400.0` is not.
///
/// Returns true to take the other device's position, false to stay here.
Future<bool> showProgressChoiceDialog(
  BuildContext context, {
  required WorkView work,
  required LibraryProgressChoice other,
  LibraryPlaybackProgress? mine,
  required String thisDevice,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: Icon(FundusIcons.sync, size: FundusIcons.sizeLg),
        title: const Text('Zwei Stände'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '„${work.title}" steht auf zwei Geräten an verschiedenen '
                  'Stellen. Wo soll es weitergehen?',
                ),
                const SizedBox(height: FundusSpace.x4),
                _Side(
                  where: thisDevice,
                  position: mine?.position,
                  at: mine?.updatedAt,
                ),
                const SizedBox(height: FundusSpace.x3),
                _Side(
                  where: other.origin,
                  position: other.position,
                  at: other.updatedAt,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Hier bleiben ($thisDevice)'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Stand von ${other.origin}'),
          ),
        ],
      ),
    ) ??
    false;

class _Side extends StatelessWidget {
  const _Side({required this.where, required this.position, required this.at});

  final String where;
  final MediaPosition? position;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Container(
      padding: const EdgeInsets.all(FundusSpace.x4),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: FundusRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(where, style: theme.textTheme.titleSmall),
          const SizedBox(height: FundusSpace.x1),
          Text(
            position == null ? 'Noch nicht geöffnet' : position!.displayValue,
            style: theme.textTheme.bodyLarge,
          ),
          if (position?.label case final label?)
            if (label != position!.displayValue)
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
          if (at case final moment?) ...[
            const SizedBox(height: FundusSpace.x1),
            Text(
              _when(moment),
              style: theme.textTheme.labelSmall?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ],
          if (position?.fraction case final fraction?) ...[
            const SizedBox(height: FundusSpace.x2),
            ClipRRect(
              borderRadius: FundusRadius.smAll,
              child: LinearProgressIndicator(value: fraction, minHeight: 4),
            ),
          ],
        ],
      ),
    );
  }

  static String _when(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year}, '
        '${two(local.hour)}:${two(local.minute)} Uhr';
  }
}
