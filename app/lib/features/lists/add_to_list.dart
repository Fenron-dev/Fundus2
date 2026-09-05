import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import 'lists_screen.dart';

/// „Zur Liste hinzufügen" — von der Seite eines Werks wie von einer Folge.
///
/// Eine Liste wächst dort, wo jemand gerade etwas hört oder liest, nicht in
/// einem Listenverwalter. Deshalb ist das Blatt kurz: die vorhandenen Listen,
/// und eine neue anlegen.
Future<void> showAddToList(
  BuildContext context, {
  required String workId,
  String? fileId,
  String? label,
}) async {
  final scope = FundusScope.of(context);
  scope.reloadPlaylists();
  final vault = scope.library.library;
  if (vault == null) return;
  if (vault.isReadOnly) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Diese Bibliothek gehört einem anderen Gerät.'),
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // Das Blatt hängt am Wurzel-Navigator und damit außerhalb des Scopes —
    // der wird deshalb mitgegeben statt aus dem Baum geholt.
    builder: (sheetContext) => SafeArea(
      child: _AddToList(
        scope: scope,
        workId: workId,
        fileId: fileId,
        label: label,
      ),
    ),
  );
}

class _AddToList extends StatefulWidget {
  const _AddToList({
    required this.scope,
    required this.workId,
    this.fileId,
    this.label,
  });

  final FundusScopeState scope;
  final String workId;
  final String? fileId;
  final String? label;

  @override
  State<_AddToList> createState() => _AddToListState();
}

class _AddToListState extends State<_AddToList> {
  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final entry = PlaylistEntry(widget.workId, fileId: widget.fileId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Zur Liste hinzufügen', style: theme.textTheme.titleSmall),
              if (widget.label case final name?)
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: FundusSpace.x3),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final list in scope.playlists)
                ListTile(
                  leading: Icon(FundusIcons.lists, color: tokens.textFaint),
                  title: Text(list.name),
                  subtitle: Text(
                    list.entries.contains(entry)
                        ? 'Steht schon darin'
                        : '${list.entries.length} Einträge',
                  ),
                  enabled: !list.entries.contains(entry),
                  onTap: () {
                    scope.addToPlaylist(list.id, entry);
                    Navigator.of(context).pop();
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(content: Text('Zu „${list.name}" gelegt.')),
                    );
                  },
                ),
              ListTile(
                leading: Icon(FundusIcons.add, color: tokens.accent),
                title: const Text('Neue Liste'),
                onTap: () async {
                  final navigator = Navigator.of(context);
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final name = await askForListName(context);
                  if (name == null) return;
                  final list = scope.createPlaylist(name);
                  if (list == null) return;
                  scope.addToPlaylist(list.id, entry);
                  navigator.pop();
                  messenger?.showSnackBar(
                    SnackBar(content: Text('„$name" angelegt.')),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: FundusSpace.x3),
      ],
    );
  }
}
