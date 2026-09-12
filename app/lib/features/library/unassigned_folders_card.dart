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
    final assignable = MediaTypes.all
        .where((type) => type.configurationKind != null)
        .toList();

    return OutlinedButton.icon(
      onPressed: () => _choose(context, scope, assignable),
      icon: Icon(FundusIcons.folder, size: FundusIcons.sizeSm),
      label: const Text('Zuordnen'),
    );
  }

  Future<void> _choose(
    BuildContext context,
    FundusScopeState scope,
    List<MediaTypeDefinition> assignable,
  ) async {
    final result = await showMediaRootAssignmentDialog(
      context,
      folder: folder,
      assignable: assignable,
    );
    if (result == null) return;
    await scope.library.assignFolder(
      result.folder,
      result.kind,
      sensitive: result.sensitive,
    );
  }
}

/// Chooses a visible folder name and its internal type. The same dialog is
/// used by the settings page for folders that have not appeared in the scan
/// yet, so custom labels such as `Hentai` can be mapped to `manga` without
/// renaming anything on disk.
Future<({String folder, String kind, bool sensitive})?>
showMediaRootAssignmentDialog(
  BuildContext context, {
  String folder = '',
  required List<MediaTypeDefinition> assignable,
}) async {
  final folderController = TextEditingController(text: folder);
  var selected = assignable.first;
  var sensitive = false;
  final result =
      await showDialog<({String folder, String kind, bool sensitive})>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(
              folder.isEmpty ? 'Medienordner hinzufügen' : '„$folder“ zuordnen',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: folderController,
                  autofocus: folder.isEmpty,
                  decoration: const InputDecoration(
                    labelText: 'Ordnername',
                    hintText: 'z. B. Hentai oder Comics',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: FundusSpace.x3),
                DropdownButtonFormField<MediaTypeDefinition>(
                  initialValue: selected,
                  decoration: const InputDecoration(
                    labelText: 'Interner Medientyp',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final type in assignable)
                      DropdownMenuItem(value: type, child: Text(type.label)),
                  ],
                  onChanged: (value) => setState(() => selected = value!),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Als HHH kennzeichnen'),
                  subtitle: const Text(
                    'Alle Werke unter diesem Ordner werden geschützt.',
                  ),
                  value: sensitive,
                  onChanged: (value) => setState(() => sensitive = value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () {
                  final value = folderController.text.trim();
                  if (value.isEmpty) return;
                  Navigator.of(context).pop((
                    folder: value,
                    kind: selected.configurationKind!,
                    sensitive: sensitive,
                  ));
                },
                child: const Text('Speichern'),
              ),
            ],
          ),
        ),
      );
  folderController.dispose();
  return result;
}
