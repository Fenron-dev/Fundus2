import 'package:fundus_core/fundus_core.dart';

import 'remote_client.dart';

/// Was ein Durchgang an Listen bewegt hat.
final class PlaylistSyncReport {
  const PlaylistSyncReport({
    this.pulled = 0,
    this.pushed = 0,
    this.removedHere = 0,
    this.removedThere = 0,
  });

  final int pulled;
  final int pushed;
  final int removedHere;
  final int removedThere;

  bool get isEmpty =>
      pulled == 0 && pushed == 0 && removedHere == 0 && removedThere == 0;
}

/// Gleicht die Listen zweier Fundus-Bibliotheken ab.
///
/// Eine Liste ist keine Ansicht, sondern etwas, das jemand gemacht hat: sie
/// gehört der Bibliothek, nicht dem Gerät, auf dem sie entstand. Wer auf dem
/// MacBook eine Playlist anlegt, erwartet sie auf dem Handy — und umgekehrt.
///
/// Entschieden wird über die Fassungsnummer, die beide Seiten mitführen: die
/// höhere gewinnt. Damit auch das Löschen ankommt, merkt sich jede Seite,
/// welche Listen sie beim letzten Mal gesehen hat. Fehlt eine, die vorher da
/// war, wurde sie gelöscht; fehlt eine, die vorher nicht da war, ist sie neu.
/// Ohne dieses Gedächtnis sähen beide Fälle gleich aus, und eine gelöschte
/// Liste käme bei jedem Durchgang wieder.
final class FundusPlaylistSync {
  const FundusPlaylistSync({
    required this.library,
    required this.client,
    required this.libraryId,
    required this.sourceId,
  });

  final FundusLibrary library;
  final FundusRemoteClient client;
  final String libraryId;

  /// Die Quelle, unter der die Gegenstelle hier geführt wird — davon hängt
  /// ab, wo das Gedächtnis liegt.
  final String sourceId;

  String get _stateKey => '$sourceId-playlists';

  Future<PlaylistSyncReport> run() async {
    final remote = {
      for (final playlist in await client.playlists(libraryId))
        playlist.id: playlist,
    };
    final local = {
      for (final playlist in library.listPlaylists()) playlist.id: playlist,
    };
    final seen = await library.loadMirrorState(_stateKey);

    var pulled = 0;
    var pushed = 0;
    var removedHere = 0;
    var removedThere = 0;

    for (final entry in remote.entries) {
      final mine = local[entry.key];
      if (mine == null) {
        if (seen.containsKey(entry.key)) {
          // Hier gelöscht, drüben noch da: das Löschen reist mit.
          await client.deletePlaylist(libraryId, entry.key);
          removedThere++;
          continue;
        }
        library.adoptPlaylist(entry.value);
        pulled++;
        continue;
      }
      if (entry.value.revision > mine.revision) {
        library.adoptPlaylist(entry.value);
        pulled++;
      } else if (mine.revision > entry.value.revision) {
        await client.updatePlaylist(
          libraryId,
          mine,
          expectedRevision: entry.value.revision,
        );
        pushed++;
      }
    }

    for (final entry in local.entries) {
      if (remote.containsKey(entry.key)) continue;
      if (seen.containsKey(entry.key)) {
        // Drüben gelöscht: dann auch hier.
        library.deletePlaylist(entry.key);
        removedHere++;
        continue;
      }
      await client.createPlaylist(libraryId, entry.value);
      pushed++;
    }

    // Was jetzt beidseits steht, ist der Stand, gegen den beim nächsten Mal
    // gemessen wird.
    await library.saveMirrorState(_stateKey, {
      for (final playlist in library.listPlaylists())
        playlist.id: '${playlist.revision}',
    });

    return PlaylistSyncReport(
      pulled: pulled,
      pushed: pushed,
      removedHere: removedHere,
      removedThere: removedThere,
    );
  }
}
