import 'package:flutter/material.dart';

import '../theme/fundus_tokens.dart';
import '../tokens/fundus_icons.dart';
import '../tokens/fundus_metrics.dart';
import '../tokens/fundus_palette.dart';

/// Where a work's bytes are right now.
///
/// This is a property of the work, not a view of it: the same library screen
/// shows all five, and "offline verfügbar" is a filter rather than a section.
/// The mark never changes colour and never moves — cover top right, row right —
/// because being recognised without reading is the entire point.
enum FundusOrigin {
  local('Lokal'),
  stream('Stream'),
  offline('Offline gesichert'),
  unreachable('Nicht erreichbar'),
  archive('Im Archiv');

  const FundusOrigin(this.label);

  final String label;

  IconData get icon => switch (this) {
    FundusOrigin.local => FundusIcons.originLocal,
    FundusOrigin.stream => FundusIcons.originStream,
    FundusOrigin.offline => FundusIcons.originOffline,
    FundusOrigin.unreachable => FundusIcons.originUnreachable,
    FundusOrigin.archive => FundusIcons.originArchive,
  };

  Color get color => switch (this) {
    FundusOrigin.local => FundusPalette.originLocal,
    FundusOrigin.stream => FundusPalette.originStream,
    FundusOrigin.offline => FundusPalette.originOffline,
    FundusOrigin.unreachable => FundusPalette.originUnreachable,
    FundusOrigin.archive => FundusPalette.originArchive,
  };

  /// Whether the bytes can be reached without a network round trip.
  bool get isPlayableOffline =>
      this == FundusOrigin.local || this == FundusOrigin.offline;

  /// Maps the `availability` column of `files` and `works`.
  static FundusOrigin fromAvailability(String value) => switch (value) {
    'available' => FundusOrigin.local,
    'offline_copy' => FundusOrigin.offline,
    'remote' => FundusOrigin.stream,
    'unreachable' => FundusOrigin.unreachable,
    'in_archive' => FundusOrigin.archive,
    _ => FundusOrigin.unreachable,
  };
}

/// The origin mark. One component, used at every place a work appears.
class FundusOriginMark extends StatelessWidget {
  const FundusOriginMark(
    this.origin, {
    super.key,
    this.size = FundusIcons.sizeSm,
    this.showLabel = false,
  });

  final FundusOrigin origin;
  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final icon = Icon(origin.icon, size: size, color: origin.color);
    if (!showLabel) {
      return Tooltip(message: origin.label, child: icon);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: FundusSpace.x2),
        Text(
          origin.label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: tokens.textMuted),
        ),
      ],
    );
  }
}
