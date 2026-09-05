import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';
import '../../media/reader_controller.dart';
import '../library/work_poster.dart';
import '../../media/text_reader_controller.dart';

/// Alle Listen des Tresors.
///
/// Playlisten und Leselisten sind dasselbe Ding mit zwei Verben: eine Reihe
/// von Werken oder Titeln, die jemand von Hand zusammengestellt hat. Getrennt
/// gezeigt werden sie trotzdem, weil niemand eine Hörliste sucht, wenn er die
/// Leseliste meint.
class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FundusScope.of(context).reloadPlaylists(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final lists = scope.playlists;
    final reading = [
      for (final list in lists)
        if (isReadingList(scope, list)) list,
    ];
    final playing = [
      for (final list in lists)
        if (!isReadingList(scope, list)) list,
    ];

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x4),
      children: [
        Row(
          children: [
            Expanded(child: Text('Listen', style: theme.textTheme.titleLarge)),
            FilledButton.icon(
              onPressed: () => _create(scope),
              icon: Icon(FundusIcons.add, size: FundusIcons.sizeSm),
              label: const Text('Neue Liste'),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x2),
        Text(
          'Eine Liste ist eine Ansicht, keine Ablage: was in ihr steht, bleibt '
          'liegen, wo es liegt, und darf in drei Listen gleichzeitig stehen.',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
        ),
        const SizedBox(height: FundusSpace.x4),
        if (lists.isEmpty)
          _Empty(onCreate: () => _create(scope))
        else ...[
          if (playing.isNotEmpty) ...[
            _SectionTitle(label: 'Playlisten', count: playing.length),
            for (final list in playing) _ListTile(list: list),
            const SizedBox(height: FundusSpace.x4),
          ],
          if (reading.isNotEmpty) ...[
            _SectionTitle(label: 'Leselisten', count: reading.length),
            for (final list in reading) _ListTile(list: list),
          ],
        ],
      ],
    );
  }

  Future<void> _create(FundusScopeState scope) async {
    final name = await askForListName(context);
    if (name == null || !mounted) return;
    final list = scope.createPlaylist(name);
    if (list != null && mounted) scope.navigation.go(ListRoute(list.id));
  }
}

/// Ob eine Liste gelesen oder gehört wird.
///
/// Entschieden wird es von dem, was drinsteht — nicht von einem Schalter beim
/// Anlegen. Wer Mangas hineinlegt, hat eine Leseliste gebaut, ganz gleich wie
/// er sie genannt hat. Eine leere Liste ist eine Playliste, weil das der
/// häufigere Fall ist und die erste Zeile die Frage ohnehin beantwortet.
bool isReadingList(FundusScopeState scope, LibraryPlaylist list) {
  var readable = 0;
  var known = 0;
  for (final entry in list.entries) {
    final work = scope.library.workById(entry.workId);
    if (work == null) continue;
    known++;
    if (ReaderController.handles(work) || TextReaderController.handles(work)) {
      readable++;
    }
  }
  return known > 0 && readable == known;
}

/// Fragt nach einem Namen — beim Anlegen wie beim Umbenennen.
Future<String?> askForListName(
  BuildContext context, {
  String initial = '',
  String title = 'Neue Liste',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(initial: initial, title: title),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Der Dialog hält seinen Textfeld-Zustand selbst.
///
/// Ein Controller, den der Aufrufer nach `showDialog` wegräumt, lebt kürzer
/// als der Dialog: der blendet sich noch aus und baut dabei ein Textfeld, das
/// es nicht mehr gibt.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial, required this.title});

  final String initial;
  final String title;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _name,
      autofocus: true,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.of(context).pop(value),
      decoration: const InputDecoration(
        labelText: 'Name',
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_name.text),
        child: const Text('Speichern'),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(width: FundusSpace.x2),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

class _ListTile extends StatelessWidget {
  const _ListTile({required this.list});

  final LibraryPlaylist list;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final works = [
      for (final entry in list.entries) ?scope.library.workById(entry.workId),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: Material(
        color: tokens.surface,
        borderRadius: FundusRadius.mdAll,
        child: InkWell(
          borderRadius: FundusRadius.mdAll,
          onTap: () => scope.navigation.go(ListRoute(list.id)),
          child: Padding(
            padding: const EdgeInsets.all(FundusSpace.x3),
            child: Row(
              children: [
                _Stack(works: works),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(list.name, style: theme.textTheme.titleSmall),
                      Text(
                        list.entries.isEmpty
                            ? 'Noch leer'
                            : '${list.entries.length} Einträge',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(FundusIcons.forward, color: tokens.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Die ersten Cover der Liste, leicht versetzt — so sieht man, was drin ist,
/// bevor man sie öffnet.
class _Stack extends StatelessWidget {
  const _Stack({required this.works});

  final List<WorkView> works;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final shown = works.take(3).toList(growable: false);
    if (shown.isEmpty) {
      return SizedBox(
        width: 56,
        height: 56,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: FundusRadius.smAll,
          ),
          child: Icon(FundusIcons.lists, color: tokens.textFaint),
        ),
      );
    }
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        children: [
          for (var index = shown.length - 1; index >= 0; index--)
            Positioned(
              left: index * 8,
              top: 0,
              bottom: 0,
              width: 40,
              child: ClipRRect(
                borderRadius: FundusRadius.smAll,
                child: WorkImage(work: shown[index]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Column(
      children: [
        const SizedBox(height: FundusSpace.x6),
        Icon(FundusIcons.lists, size: 48, color: tokens.textFaint),
        const SizedBox(height: FundusSpace.x3),
        Text('Noch keine Liste', style: theme.textTheme.titleSmall),
        const SizedBox(height: FundusSpace.x2),
        Text(
          'Auf der Seite eines Werks liegt „Zur Liste hinzufügen" — von dort '
          'wächst eine Liste, während man sie hört oder liest.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
        ),
        const SizedBox(height: FundusSpace.x3),
        FilledButton(onPressed: onCreate, child: const Text('Neue Liste')),
      ],
    );
  }
}
