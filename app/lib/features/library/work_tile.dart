import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import 'work_cover.dart';

/// A work in the tile grid.
class WorkTile extends StatelessWidget {
  const WorkTile({super.key, required this.work, required this.onTap});

  final WorkView work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final density = tokens.density;

    return InkWell(
      onTap: onTap,
      borderRadius: FundusRadius.mdAll,
      hoverColor: tokens.hover,
      child: Padding(
        padding: EdgeInsets.all(density.tilePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            WorkCover(work: work),
            const SizedBox(height: FundusSpace.x3),
            Text(
              work.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (work.subtitle.isNotEmpty)
              Text(
                work.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
              ),
            if (work.progressLabel != null)
              Text(
                work.progressLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: work.finished
                      ? tokens.success
                      : tokens.accentRamp.s400,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A work as a table row — the same work, denser.
class WorkRow extends StatelessWidget {
  const WorkRow({super.key, required this.work, required this.onTap});

  final WorkView work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final density = tokens.density;
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      hoverColor: tokens.hover,
      child: Container(
        height: density.rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x3),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: density.rowHeight * 0.62,
              child: WorkCover(
                work: work,
                aspectRatio: 1,
                showProgress: false,
                showOrigin: false,
              ),
            ),
            const SizedBox(width: FundusSpace.x3),
            Expanded(
              flex: 4,
              child: Text(
                work.title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                work.subtitle,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ),
            SizedBox(
              width: 140,
              child: work.progressLabel == null
                  ? const SizedBox.shrink()
                  : Text(
                      work.progressLabel!,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: work.finished
                            ? tokens.success
                            : tokens.textMuted,
                      ),
                    ),
            ),
            const SizedBox(width: FundusSpace.x3),
            FundusOriginMark(work.origin),
          ],
        ),
      ),
    );
  }
}
