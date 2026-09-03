import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';

/// Folders the scan walked past because no media area claims their name.
///
/// The scanner only indexes below configured folders. A collection called
/// "Anime", or a "Webnovels" folder later renamed to "Light Novels", therefore
/// yields nothing at all — and an empty area with no explanation is the dead
/// end the design warns about. So the folders are named here, with their file
/// count, and one click assigns them. The assignment is stored in the
/// library's own `config.yaml`, so it travels with the vault.
class UnassignedFoldersCard extends StatelessWidget {
  const UnassignedFoldersCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final folders = scope.library.unassignedFolders;
    if (folders.isEmpty) return const SizedBox.shrink();

    final tokens = context.fundus;
    final theme = Theme.of(context);
    final entries = folders.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      margin: const EdgeInsets.only(bottom: FundusSpace.x8),
      padding: const EdgeInsets.all(FundusSpace.x6),
      decoration: BoxDecoration(
        color: tokens.warningGround,
        borderRadius: FundusRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FundusIcons.warning,
                size: FundusIcons.sizeMd,
                color: tokens.warning,
              ),
              const SizedBox(width: FundusSpace.x3),
              Text(
                'Nicht zugeordnete Ordner',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: tokens.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: FundusSpace.x3),
          Text(
            'Eingelesen wird nur, was unter einem bekannten Medienordner '
            'liegt. Diese Ordner kennt die Bibliothek noch nicht — die '
            'Zuordnung wird in der Bibliothek gespeichert und gilt damit auf '
            'jedem Gerät.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.warning),
          ),
          const SizedBox(height: FundusSpace.x6),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: FundusSpace.x3),
              child: Row(
                children: [
                  Icon(
                    FundusIcons.folder,
                    size: FundusIcons.sizeSm,
                    color: tokens.warning,
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    child: Text(
                      entry.key,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${entry.value} Dateien',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x4),
                  _AssignButton(folder: entry.key),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AssignButton extends StatelessWidget {
  const _AssignButton({required this.folder});

  final String folder;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final assignable = MediaTypes.all
        .where((type) => type.configurationKind != null)
        .toList();

    return PopupMenuButton<String>(
      tooltip: 'Medientyp zuweisen',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      onSelected: (kind) => scope.library.assignFolder(folder, kind),
      itemBuilder: (context) => [
        for (final type in assignable)
          PopupMenuItem(
            value: type.configurationKind,
            child: Row(
              children: [
                Icon(type.icon, size: FundusIcons.sizeSm),
                const SizedBox(width: FundusSpace.x3),
                Text(type.label),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x3,
          vertical: FundusSpace.x2,
        ),
        decoration: BoxDecoration(
          borderRadius: FundusRadius.mdAll,
          border: Border.fromBorderSide(BorderSide(color: tokens.warning)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Zuordnen',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: tokens.warning),
            ),
            const SizedBox(width: FundusSpace.x2),
            Icon(
              FundusIcons.collapse,
              size: FundusIcons.sizeSm,
              color: tokens.warning,
            ),
          ],
        ),
      ),
    );
  }
}
