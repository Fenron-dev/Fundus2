import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import 'work_poster.dart';

/// A work as one line, for the table view and the lists inside a group.
///
/// The dividing rule is gone. A row is separated from the next by the space
/// around it and by the artwork at its head; a line under every entry is what
/// made a library look like a spreadsheet. On a narrow screen the columns
/// stack into two lines rather than being squeezed into four.
class WorkRow extends StatelessWidget {
  const WorkRow({
    super.key,
    required this.work,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final WorkView work;
  final VoidCallback onTap;

  /// Beginnt die Mehrfachauswahl.
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final artwork = tokens.density == FundusDensity.compact ? 34.0 : 44.0;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x2,
        vertical: 2,
      ),
      child: Material(
        color: selected ? tokens.accentTint(0.22) : Colors.transparent,
        borderRadius: FundusRadius.mdAll,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: FundusRadius.mdAll,
          hoverColor: tokens.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FundusSpace.x3,
              vertical: FundusSpace.x2,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: artwork,
                  child: WorkArtwork(
                    work: work,
                    aspectRatio: 1,
                    borderRadius: FundusRadius.smAll,
                    showProgress: false,
                    showOrigin: false,
                  ),
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (work.subtitle.isNotEmpty || !wide)
                        Text(
                          [
                            if (work.subtitle.isNotEmpty) work.subtitle,
                            if (!wide && work.progressLabel != null)
                              work.progressLabel!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: tokens.textFaint,
                          ),
                        ),
                    ],
                  ),
                ),
                if (wide && work.progressLabel != null) ...[
                  const SizedBox(width: FundusSpace.x3),
                  Text(
                    work.progressLabel!,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: work.finished ? tokens.success : tokens.textMuted,
                    ),
                  ),
                ],
                const SizedBox(width: FundusSpace.x3),
                FundusOriginMark(work.origin),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
