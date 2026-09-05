import 'dart:async';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';
import '../../media/playback_preference.dart';
import '../library/work_poster.dart';
import 'lists_screen.dart';

/// Eine Liste, Zeile für Zeile.
///
/// Angetippt wird nicht „die Liste", sondern die Stelle: wer die vierte Zeile
/// wählt, will dort anfangen und danach weiterhören. Deshalb startet jede
/// Zeile dieselbe Liste, nur an anderer Stelle.
class ListScreen extends StatefulWidget {
  const ListScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
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
    final list = scope.playlists
        .where((entry) => entry.id == widget.playlistId)
        .firstOrNull;

    if (list == null) {
      return Center(
        child: Text(
          'Diese Liste gibt es nicht mehr.',
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textFaint),
        ),
      );
    }

    final reading = isReadingList(scope, list);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(FundusSpace.x4),
          child: _Head(list: list, reading: reading),
        ),
        Expanded(
          child: list.entries.isEmpty
              ? Center(
                  child: Text(
                    'Diese Liste ist leer.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(
                    left: FundusSpace.x4,
                    right: FundusSpace.x4,
                    bottom: FundusSpace.x6,
                  ),
                  itemCount: list.entries.length,
                  onReorder: (from, to) => scope.reorderPlaylist(
                    list.id,
                    from,
                    to > from ? to - 1 : to,
                  ),
                  itemBuilder: (context, index) => _EntryRow(
                    key: ValueKey('${list.id}-$index'),
                    list: list,
                    index: index,
                    reading: reading,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Wo eine Zeile in der abgespielten Reihenfolge anfängt.
///
/// Eine Zeile ist nicht ein Titel: ein ganzes Werk in der Liste bringt alle
/// seine Dateien mit. Wer also die dritte Zeile antippt, meint nicht
/// unbedingt den dritten Titel.
int queueStartFor(FundusScopeState scope, LibraryPlaylist list, int entry) {
  final vault = scope.library.library;
  if (vault == null) return 0;
  var start = 0;
  for (var index = 0; index < entry && index < list.entries.length; index++) {
    final line = list.entries[index];
    if (scope.library.workById(line.workId) == null) continue;
    final tracks = vault.playbackTracks(line.workId);
    start += line.fileId == null
        ? tracks.length
        : tracks.where((track) => track.fileId == line.fileId).length;
  }
  return start;
}

class _Head extends StatelessWidget {
  const _Head({required this.list, required this.reading});

  final LibraryPlaylist list;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final player = scope.player;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(list.name, style: theme.textTheme.titleLarge),
                  Text(
                    [
                      reading ? 'Leseliste' : 'Playliste',
                      '${list.entries.length} Einträge',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => unawaited(_rename(context, scope)),
                  child: const Text('Umbenennen'),
                ),
                MenuItemButton(
                  onPressed: () {
                    scope.deletePlaylist(list.id);
                    scope.navigation.go(const ListsRoute());
                  },
                  child: const Text('Liste löschen'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                onPressed: controller.isOpen
                    ? controller.close
                    : controller.open,
                icon: Icon(FundusIcons.more),
                tooltip: 'Mehr',
              ),
            ),
          ],
        ),
        const SizedBox(height: FundusSpace.x3),
        Wrap(
          spacing: FundusSpace.x2,
          runSpacing: FundusSpace.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: list.entries.isEmpty
                  ? null
                  : () => unawaited(_start(scope, shuffle: false)),
              icon: Icon(FundusIcons.play, size: FundusIcons.sizeSm),
              label: Text(reading ? 'Weiterlesen' : 'Abspielen'),
            ),
            if (!reading)
              OutlinedButton.icon(
                onPressed: list.entries.isEmpty
                    ? null
                    : () => unawaited(_start(scope, shuffle: true)),
                icon: Icon(FundusIcons.shuffle, size: FundusIcons.sizeSm),
                label: const Text('Zufällig'),
              ),
            if (!reading) ...[
              // Loop gehört zur Liste, nicht zum Titel: „die Liste noch
              // einmal" ist die Frage, die sich am Ende stellt.
              OutlinedButton.icon(
                onPressed: player.cycleRepeat,
                icon: Icon(
                  player.repeatMode == RepeatMode.one
                      ? FundusIcons.repeatOne
                      : FundusIcons.repeat,
                  size: FundusIcons.sizeSm,
                  color: player.repeatMode == RepeatMode.none
                      ? null
                      : tokens.accent,
                ),
                label: Text(player.repeatMode.label),
              ),
              const _SleepChoice(),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _start(FundusScopeState scope, {required bool shuffle}) async {
    if (reading) {
      // Eine Leseliste macht dort weiter, wo noch etwas offen ist.
      final next = _nextToRead(scope);
      if (next != null) await scope.play(next);
      return;
    }
    if (shuffle != scope.player.isShuffling) {
      await scope.player.setShuffle(shuffle);
    }
    await scope.playPlaylist(list);
  }

  WorkView? _nextToRead(FundusScopeState scope) {
    WorkView? first;
    for (final entry in list.entries) {
      final work = scope.library.workById(entry.workId);
      if (work == null) continue;
      first ??= work;
      if (!work.summary.progressFinished) return work;
    }
    return first;
  }

  Future<void> _rename(BuildContext context, FundusScopeState scope) async {
    final name = await askForListName(
      context,
      initial: list.name,
      title: 'Liste umbenennen',
    );
    if (name == null) return;
    scope.renamePlaylist(list.id, name);
  }
}

/// Der Schlafzeitgeber, schon von der Liste aus.
///
/// Wer eine Liste zum Einschlafen startet, stellt ihn vorher — nicht, wenn er
/// schon halb schläft.
class _SleepChoice extends StatelessWidget {
  const _SleepChoice();

  @override
  Widget build(BuildContext context) {
    final player = FundusScope.of(context).player;
    final left = player.sleepRemaining;
    if (left != null) {
      return OutlinedButton.icon(
        onPressed: player.cancelSleepTimer,
        icon: Icon(FundusIcons.sleepTimer, size: FundusIcons.sizeSm),
        label: Text('noch ${left.inMinutes} min'),
      );
    }
    return MenuAnchor(
      menuChildren: [
        for (final minutes in PlaybackPreference.sleepChoices)
          MenuItemButton(
            onPressed: () => player.startSleepTimer(Duration(minutes: minutes)),
            child: Text('$minutes Minuten'),
          ),
      ],
      builder: (context, controller, _) => OutlinedButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: Icon(FundusIcons.sleepTimer, size: FundusIcons.sizeSm),
        label: const Text('Sleep'),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    super.key,
    required this.list,
    required this.index,
    required this.reading,
  });

  final LibraryPlaylist list;
  final int index;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final entry = list.entries[index];
    final work = scope.library.workById(entry.workId);

    if (work == null) {
      return ListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        leading: Icon(FundusIcons.warning, color: tokens.textFaint),
        title: const Text('Nicht mehr in der Bibliothek'),
        subtitle: Text(
          'Die Zeile bleibt stehen, bis jemand sie entfernt.',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
        ),
        trailing: IconButton(
          onPressed: () => scope.removeFromPlaylist(list.id, index),
          icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
          tooltip: 'Entfernen',
        ),
      );
    }

    final title = _trackTitle(scope, entry) ?? work.title;
    final subtitle = [
      if (_trackTitle(scope, entry) != null) work.title,
      work.summary.author,
    ].where((value) => value.trim().isNotEmpty).join(' · ');

    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: FundusSpace.x2),
      child: Material(
        color: tokens.surface,
        borderRadius: FundusRadius.mdAll,
        child: InkWell(
          borderRadius: FundusRadius.mdAll,
          onTap: () => unawaited(_open(scope, work)),
          child: Padding(
            padding: const EdgeInsets.all(FundusSpace.x2),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: ClipRRect(
                    borderRadius: FundusRadius.smAll,
                    child: WorkImage(work: work),
                  ),
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.textFaint,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => scope.removeFromPlaylist(list.id, index),
                  icon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
                  tooltip: 'Aus der Liste nehmen',
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FundusSpace.x2,
                    ),
                    child: Icon(FundusIcons.viewTable, color: tokens.textFaint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _open(FundusScopeState scope, WorkView work) async {
    if (reading) {
      await scope.play(work);
      return;
    }
    await scope.playPlaylist(
      list,
      startIndex: queueStartFor(scope, list, index),
    );
  }

  /// Der Name der Datei, wenn die Zeile eine einzelne meint.
  String? _trackTitle(FundusScopeState scope, PlaylistEntry entry) {
    final fileId = entry.fileId;
    final vault = scope.library.library;
    if (fileId == null || vault == null) return null;
    for (final track in vault.playbackTracks(entry.workId)) {
      if (track.fileId == fileId) return track.title;
    }
    return null;
  }
}
