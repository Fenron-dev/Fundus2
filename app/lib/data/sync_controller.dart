import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';

import '../app/app_settings.dart';
import 'library_controller.dart';
import 'peer_connection.dart';

/// Connecting to another Fundus and keeping both sides in step.
///
/// It owns no rules of its own — pairing lives in the client package and the
/// reconciliation in [FundusSync]. What it owns is the part that belongs to
/// this app: which connections exist, when they last ran, and what to say
/// about it.
class SyncController extends ChangeNotifier {
  SyncController({
    required this.settings,
    required this.library,
    FundusRemoteClient Function(PeerConnection peer)? connect,
  }) : _connect = connect ?? _defaultConnect;

  final AppSettings settings;
  final LibraryController library;

  /// How a connection is opened. Injectable so a test can answer without a
  /// network.
  final FundusRemoteClient Function(PeerConnection peer) _connect;

  static FundusRemoteClient _defaultConnect(PeerConnection peer) =>
      FundusRemoteClient(
        baseUri: peer.baseUri,
        token: peer.token,
        certificateFingerprint: peer.certificateFingerprint,
      );

  bool _busy = false;
  String? _failure;

  bool get isBusy => _busy;
  String? get failure => _failure;
  List<PeerConnection> get peers => settings.peers;

  /// Pairs with the Fundus a code came from.
  ///
  /// The code says where and who; the PIN, read off the other screen, says
  /// that it really is the person standing there.
  Future<bool> pair({required String code, required String pin}) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final parsed = FundusPairingCode.parse(code);
      final result = await FundusRemoteClient.claim(
        code: parsed,
        pin: pin,
        deviceId: settings.deviceKey,
        deviceName: settings.deviceName,
      );
      await settings.savePeer(
        PeerConnection(
          serverId: result.serverId,
          name: result.serverName.isEmpty
              ? (parsed.serverName ?? 'Fundus')
              : result.serverName,
          baseUrl: parsed.baseUri.toString(),
          token: result.token,
          certificateFingerprint: parsed.certificateFingerprint,
        ),
      );
      _busy = false;
      notifyListeners();
      return true;
    } on FormatException catch (error) {
      _failure = error.message;
    } on FundusRemoteException catch (error) {
      _failure = error.message;
    } on Object catch (error) {
      _failure = 'Die Kopplung ist fehlgeschlagen: $error';
    }
    _busy = false;
    notifyListeners();
    return false;
  }

  Future<void> forget(String serverId) async {
    await settings.forgetPeer(serverId);
    notifyListeners();
  }

  /// Brings this vault and the peer's matching library to the same state.
  ///
  /// What this reconciles is reading state — positions, bookmarks, highlights
  /// — between two copies of the same vault. It is not a way to reach the
  /// other side's files: a work exists on both sides or there is nothing to
  /// reconcile. Opening a paired Fundus's library on a device that has none
  /// of its own is the next piece of work, and until it exists this says so
  /// rather than asking for something that cannot be done.
  Future<SyncReport?> syncWith(PeerConnection peer) async {
    final vault = library.library;
    if (vault == null) {
      _failure =
          'Dieses Gerät hat keine eigene Bibliothek. Der Abgleich hält '
          'zurzeit zwei Kopien derselben Bibliothek auf demselben Stand — '
          'er holt die Bibliothek von „${peer.name}" noch nicht hierher. '
          'Das kommt als Nächstes.';
      notifyListeners();
      return null;
    }
    _busy = true;
    _failure = null;
    notifyListeners();

    final client = _connect(peer);
    try {
      final libraryId = await _libraryIdFor(peer, client, vault);
      if (libraryId == null) {
        final offered = await client.libraries();
        _failure = offered.isEmpty
            ? 'Auf „${peer.name}" ist gerade keine Bibliothek freigegeben.'
            : 'Die hier geöffnete Bibliothek gibt es auf „${peer.name}" '
                  'nicht — dort liegt ${_naming(offered)}. Abgeglichen '
                  'werden kann nur zwischen zwei Kopien derselben '
                  'Bibliothek; eine fremde Bibliothek hier zu öffnen, kommt '
                  'als Nächstes.';
        _busy = false;
        notifyListeners();
        return null;
      }

      final report = await FundusSync(
        library: vault,
        client: client,
        libraryId: libraryId,
        deviceId: settings.deviceKey,
        peerName: peer.name,
        baseline: SyncBaseline(await vault.loadSyncBaseline(peer.serverId)),
      ).run(workIds: await _worthSyncing(vault, peer, client, libraryId));
      await _record(vault, peer, report);

      await settings.savePeer(
        peer.copyWith(
          libraryId: libraryId,
          lastSyncAt: DateTime.now(),
          lastResult: report.summary,
        ),
      );
      // Positions and marks changed underneath the views, so they have to be
      // read again — the library is the one truth, not the screen.
      library.refresh();
      _busy = false;
      notifyListeners();
      return report;
    } on FundusRemoteException catch (error) {
      _failure = error.message;
    } on Object catch (error) {
      _failure = 'Der Abgleich ist fehlgeschlagen: $error';
    } finally {
      client.close();
    }
    _busy = false;
    notifyListeners();
    return null;
  }

  /// Sends one work's reading state on, quietly.
  ///
  /// Called when a player or a reader is closed. Pressing a button after
  /// every chapter is not a synchronisation, it is a chore — and the case
  /// this exists for is finishing an episode on the phone and finding the
  /// Mac at the same place. It reports nothing and disturbs nothing: a peer
  /// that is asleep simply does not answer.
  /// How long a machine gets to answer before playback goes ahead.
  ///
  /// This runs between pressing play and anything happening, so it is short
  /// on purpose. A Mac that is asleep must cost a moment, not the evening.
  static const askTimeout = Duration(milliseconds: 1800);

  /// Asks every paired machine where *this one work* stands, right now.
  ///
  /// The periodic round is the wrong tool for the question „ich habe eben am
  /// Mac aufgehört, wo bin ich?" — it runs over the whole catalogue, at its
  /// own rhythm, about works nobody is thinking about. One work, one call, at
  /// the moment somebody wants that work, is what makes a position show up
  /// straight away on whichever device is picked up next.
  ///
  /// Returns the furthest position any machine reports, or null when nobody
  /// answers in time and when nobody has anything.
  Future<({RemoteProgress progress, String peerName})?> furthestElsewhere(
    String workId,
  ) async {
    final vault = library.library;
    if (vault == null || peers.isEmpty) return null;
    final asked = await Future.wait([
      for (final peer in peers) _askOne(peer, vault, workId),
    ]);
    // Welche Stelle weiter ist, entscheidet nicht die Seitenzahl allein: bei
    // einem Manga fängt jedes Kapitel wieder bei Seite eins an.
    final order = [
      for (final track in vault.playbackTracks(workId)) track.fileId,
    ];
    ({RemoteProgress progress, String peerName})? best;
    for (final answer in asked) {
      if (answer == null) continue;
      if (best == null ||
          comparePositions(
                answer.progress.position,
                best.progress.position,
                fileOrder: order,
              ) >
              0) {
        best = answer;
      }
    }
    return best;
  }

  /// Was jedes gekoppelte Gerät zu diesem einen Werk sagt.
  ///
  /// Nicht „das weiteste", sondern alle: die Geräteseite eines Werks zeigt,
  /// wer wo steht, und lässt dann wählen. Ein Gerät, das schläft, fehlt
  /// einfach — das ist die Auskunft, nicht ein Fehler.
  Future<List<({String peerName, String serverId, RemoteProgress progress})>>
  progressEverywhere(String workId) async {
    final vault = library.library;
    if (vault == null || peers.isEmpty) return const [];
    final asked = await Future.wait([
      for (final peer in peers) _askMany(peer, vault, workId),
    ]);
    return [
      for (var peerIndex = 0; peerIndex < asked.length; peerIndex++)
        for (final progress in asked[peerIndex])
          (
            peerName: peerNameForProgress(peers[peerIndex], progress),
            serverId: peers[peerIndex].serverId,
            progress: progress,
          ),
    ];
  }

  /// Reads the per-device journal exposed by a paired server. A server may
  /// have several clients (phone, tablet, desktop); asking only for its
  /// current row made the last writer hide all the others.
  Future<List<RemoteProgress>> _askMany(
    PeerConnection peer,
    FundusLibrary vault,
    String workId,
  ) async {
    final client = _connect(peer);
    try {
      final libraryId = await _libraryIdFor(
        peer,
        client,
        vault,
      ).timeout(askTimeout);
      if (libraryId == null) return const [];
      final revisions = await client
          .progressRevisions(libraryId, workId)
          .timeout(askTimeout);
      // One row per device: revisions are deliberately a history, while the
      // device screen answers the question „where does each stand now?".
      final latest = <String, RemoteProgress>{};
      for (final revision in revisions) {
        final previous = latest[revision.deviceId];
        if (previous == null ||
            revision.updatedAt.isAfter(previous.updatedAt)) {
          latest[revision.deviceId] = revision;
        }
      }
      return latest.values.toList(growable: false);
    } on Object {
      return const [];
    } finally {
      client.close();
    }
  }

  String peerNameForProgress(PeerConnection peer, RemoteProgress progress) =>
      progress.deviceName.trim().isNotEmpty
      ? progress.deviceName
      : progress.deviceId.isEmpty || progress.deviceId == peer.serverId
      ? peer.name
      : '${peer.name} · ${progress.deviceId}';

  Future<({RemoteProgress progress, String peerName})?> _askOne(
    PeerConnection peer,
    FundusLibrary vault,
    String workId,
  ) async {
    final client = _connect(peer);
    try {
      final libraryId = await _libraryIdFor(
        peer,
        client,
        vault,
      ).timeout(askTimeout);
      if (libraryId == null) return null;
      final progress = await client
          .progress(libraryId, workId)
          .timeout(askTimeout);
      if (progress == null) return null;
      return (progress: progress, peerName: peer.name);
    } on Object {
      // A machine that is off, asleep or slow is not news here: the work
      // opens at the position this device knows.
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> pushWork(String workId) async {
    final vault = library.library;
    if (vault == null || peers.isEmpty || _busy) return;
    for (final peer in peers) {
      final client = _connect(peer);
      try {
        final libraryId = await _libraryIdFor(peer, client, vault);
        if (libraryId == null) continue;
        final report = await FundusSync(
          library: vault,
          client: client,
          libraryId: libraryId,
          deviceId: settings.deviceKey,
          peerName: peer.name,
          baseline: SyncBaseline(await vault.loadSyncBaseline(peer.serverId)),
        ).run(workIds: [workId]);
        await _record(vault, peer, report);
      } on Object {
        // Silence is the right answer here. This runs on the way out of a
        // player; a machine that is switched off is not news, and the manual
        // sync says so properly when the person asks.
      } finally {
        client.close();
      }
    }
  }

  /// Holt nur, was sich drüben bewegt hat.
  ///
  /// Der große Abgleich fragt jedes Werk einzeln — bei zehntausend Werken
  /// ist das anderthalb Minuten, und deshalb drückte man den Knopf von Hand
  /// und wartete. Hier wird einmal gefragt, welche Werke einen neuen Stand
  /// haben, und nur die werden abgeglichen. Das ist billig genug, um von
  /// selbst zu laufen.
  ///
  /// Gibt die Werke zurück, die sich geändert haben — die Oberfläche frischt
  /// genau diese Zeilen auf, statt die ganze Bibliothek neu zu lesen.
  /// Wie viele Werke ein Auffrischen höchstens anfasst.
  ///
  /// Der Rest kommt in der nächsten Runde. Eine Bibliothek mit hunderten
  /// angefangenen Werken darf beim ersten Blick nicht hunderte Anfragen
  /// auslösen — genau das hat den Server zugeschüttet.
  static const catchUpBatch = 25;

  /// Holt nur, was sich drüben bewegt hat.
  ///
  /// Ausdrücklich nur *holen*: kein Zurückschieben, keine Notizen. Der
  /// vollständige Abgleich schiebt auch — und weil jedes Schieben drüben
  /// einen neuen Zeitstempel setzt, fand die nächste Runde dieselben Werke
  /// wieder als „geändert" vor. Das war die Endlosschleife im Protokoll.
  ///
  /// Gibt die Werke zurück, die sich geändert haben — die Oberfläche frischt
  /// genau diese Zeilen auf, statt die ganze Bibliothek neu zu lesen.
  Future<Set<String>> pullRecent() async {
    final vault = library.library;
    if (vault == null || peers.isEmpty || _busy) return const {};
    final touched = <String>{};
    for (final peer in peers) {
      final client = _connect(peer);
      try {
        final libraryId = await _libraryIdFor(peer, client, vault);
        if (libraryId == null) continue;
        final changed = await client.progressChangedSince(
          libraryId,
          since: _lastPull[peer.serverId],
        );
        if (changed.isEmpty) continue;
        // Von hinten nach vorn: die ältesten zuerst, damit der Merkzeitpunkt
        // lückenlos weiterwandert, wenn eine Runde nicht alles schafft.
        final queue = changed.toList()
          ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
        var done = 0;
        for (final entry in queue) {
          if (done >= catchUpBatch) break;
          _lastPull[peer.serverId] = entry.updatedAt;
          done++;
          final mine = vault.loadProgress(entry.workId);
          // Nur ein nachweislich älterer Stand kann sicher übersprungen werden.
          // Millisekunden sind keine eindeutige Änderungs-ID: zwei Geräte
          // können denselben Zeitstempel erzeugen. Gleich alte Einträge müssen
          // deshalb geladen und von _carryOver anhand der Position entschieden
          // werden, sonst gehen Fortschritte oder Konfliktfragen verloren.
          if (mine != null && entry.updatedAt.isBefore(mine.updatedAt)) {
            continue;
          }
          final theirs = await client.progress(libraryId, entry.workId);
          if (theirs == null) continue;
          if (_carryOver(vault, peer, mine, theirs)) touched.add(entry.workId);
        }
      } on Object {
        // Ein Gerät, das gerade schläft, ist keine Meldung wert — dies läuft
        // im Hintergrund, und der Knopf sagt es richtig, wenn jemand fragt.
      } finally {
        client.close();
      }
    }
    if (touched.isNotEmpty) notifyListeners();
    return touched;
  }

  /// Schreibt einen Stand von drüben hierher — oder legt ihn als Frage ab.
  ///
  /// Weiter *und* älter ist der einzige Fall, der nicht zu entscheiden ist:
  /// hier steht die weitere Stelle, drüben die neuere. Dann wird nichts
  /// überschrieben, sondern beim nächsten Öffnen gefragt.
  bool _carryOver(
    FundusLibrary vault,
    PeerConnection peer,
    LibraryPlaybackProgress? mine,
    RemoteProgress theirs,
  ) {
    if (vault.isReadOnly) return false;
    final order = [
      for (final track in vault.playbackTracks(theirs.workId)) track.fileId,
    ];
    final furtherHere =
        mine != null &&
        comparePositions(mine.position, theirs.position, fileOrder: order) > 0;
    // Derselbe Titel, nur eine andere Sekunde, ist keine Frage: gemeint ist
    // die weitere Stelle. Gefragt wird, wenn zwei Geräte an verschiedenen
    // Stücken eines Werks stehen — oder wenn das Werk nur aus einem Stück
    // besteht, denn dann ist dieselbe Datei das ganze Werk.
    final sameFile =
        mine != null &&
        order.length > 1 &&
        mine.position.fileId != null &&
        mine.position.fileId == theirs.position.fileId;
    if (furtherHere && sameFile) return false;
    if (furtherHere) {
      vault.recordProgressChoice(
        LibraryProgressChoice(
          workId: theirs.workId,
          position: theirs.position,
          fileId: theirs.fileId,
          finished: theirs.finished,
          deviceId: theirs.deviceId,
          deviceName: peer.name,
          updatedAt: theirs.updatedAt,
          recordedAt: DateTime.now().toUtc(),
        ),
      );
      return false;
    }
    vault.saveMediaProgress(
      workId: theirs.workId,
      fileId: theirs.fileId ?? theirs.position.fileId ?? '',
      position: theirs.position,
      finished: theirs.finished,
      deviceId: settings.deviceKey,
      updatedAt: theirs.updatedAt,
    );
    return true;
  }

  /// Bis wann von jeder Gegenstelle schon geholt wurde. Nur für diese
  /// Sitzung: beim Start einmal alles zu prüfen ist billiger, als sich zu
  /// merken, was man verpasst haben könnte.
  final Map<String, DateTime> _lastPull = {};

  Future<SyncReport?> syncAll() async {
    SyncReport? last;
    for (final peer in peers) {
      last = await syncWith(peer) ?? last;
    }
    return last;
  }

  /// Welche Werke dieser Abgleich anfasst.
  ///
  /// Nicht alle: ein Werk, das nie jemand geöffnet und nie jemand
  /// beschriftet hat, hat auf keiner Seite einen Stand, eine Notiz oder ein
  /// Schlagwort — es abzugleichen ist eine Anfrage, deren Antwort feststeht.
  /// Bei zehntausend Werken sind das zehntausend Anfragen für nichts, und
  /// genau daran ist der erste Abgleich nach dem Koppeln erstickt.
  ///
  /// Gefragt werden beide Seiten, sonst käme ein Lesezeichen, das drüben
  /// gesetzt wurde, nie herüber.
  Future<Iterable<String>> _worthSyncing(
    FundusLibrary vault,
    PeerConnection peer,
    FundusRemoteClient client,
    String libraryId,
  ) async {
    final worth = <String>{
      ...vault.worksWorthSyncing(),
      ...await client.worksWorthSyncing(libraryId),
    };
    // Und davon nur, wofür diese Gegenstelle zuständig ist: eine andere nach
    // den Werken einer dritten zu fragen wäre eine Runde 404er.
    final domain = _worksOf(vault, peer);
    if (domain == null) return worth;
    final allowed = domain.toSet();
    return worth.where(allowed.contains);
  }

  /// Which works this peer answers for.
  ///
  /// A shell vault holds several machines' catalogues at once. Asking one of
  /// them about another's works would be a round of 404s — correct, and a
  /// waste of the network the sync is trying not to depend on. Null means
  /// „everything", which is right for a vault of one's own.
  static Iterable<String>? _worksOf(FundusLibrary vault, PeerConnection peer) {
    final sourceId = 'peer-${peer.serverId}';
    final own = vault
        .listWorks(includeMissing: true)
        .where((work) => work.sourceId == sourceId)
        .map((work) => work.id)
        .toList();
    return own.isEmpty ? null : own;
  }

  /// Writes down what was agreed and what was decided.
  ///
  /// The baseline is the point the next run measures from; the journal is
  /// what a person reads when a position turns up where they did not leave
  /// it. Both belong to the library, not to this installation.
  Future<void> _record(
    FundusLibrary vault,
    PeerConnection peer,
    SyncReport report,
  ) async {
    if (vault.isReadOnly) return;
    await vault.saveSyncBaseline(peer.serverId, report.agreedMarks);
    if (report.entries.isEmpty) return;
    final previous = await vault.loadSyncJournal(peer.serverId);
    await vault.saveSyncJournal(peer.serverId, [
      for (final entry in report.entries.reversed) entry.toJson(),
      ...previous,
    ]);
    _journal = null;
  }

  /// The journal of the peer last synced with, newest first.
  List<SyncEntry>? _journal;

  List<SyncEntry> get journal => _journal ?? const [];

  /// Reads the journal for a peer. Held until the next sync writes to it.
  Future<List<SyncEntry>> loadJournal(PeerConnection peer) async {
    final vault = library.library;
    if (vault == null) return const [];
    final raw = await vault.loadSyncJournal(peer.serverId);
    final entries = [for (final entry in raw) SyncEntry.fromJson(entry)];
    _journal = entries;
    notifyListeners();
    return entries;
  }

  /// Turns a decision around: takes the other side's value after all.
  ///
  /// This is what makes „der neuere Stand gewinnt" bearable — the rule
  /// decides in the moment, and a person who disagrees can say so afterwards
  /// without hunting for the position by hand.
  Future<bool> revert(PeerConnection peer, SyncEntry entry) async {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return false;
    _busy = true;
    _failure = null;
    notifyListeners();
    final client = _connect(peer);
    try {
      final libraryId = await _libraryIdFor(peer, client, vault);
      if (libraryId == null) return _finish(false);
      final theirs = await client.progress(libraryId, entry.workId);
      if (theirs == null) {
        _failure = 'Auf der Gegenstelle steht für dieses Werk nichts mehr.';
        return _finish(false);
      }
      vault.saveMediaProgress(
        workId: entry.workId,
        fileId: theirs.fileId ?? '',
        position: theirs.position,
        finished: theirs.finished,
        deviceId: theirs.deviceId.isEmpty
            ? settings.deviceKey
            : theirs.deviceId,
      );
      // The baseline must forget this work, or the next run would call the
      // change a conflict with itself.
      final baseline = await vault.loadSyncBaseline(peer.serverId)
        ..remove(entry.workId);
      await vault.saveSyncBaseline(peer.serverId, baseline);
      library.refresh();
      return _finish(true);
    } on FundusRemoteException catch (error) {
      _failure = error.message;
    } on Object catch (error) {
      _failure = 'Das ließ sich nicht zurücknehmen: $error';
    } finally {
      client.close();
    }
    return _finish(false);
  }

  bool _finish(bool value) {
    _busy = false;
    notifyListeners();
    return value;
  }

  static String _naming(List<RemoteLibrary> libraries) => libraries.length == 1
      ? '„${libraries.single.name}"'
      : '${libraries.length} andere';

  /// Which library over there is the one open here.
  ///
  /// Two cases, and they are answered differently.
  ///
  /// A vault that mirrors this peer says so itself: it carries a source row
  /// for it naming the library the works came from. That is authoritative and
  /// costs no request.
  ///
  /// Otherwise this is a vault of its own, and the match is by the vault's id
  /// — not by name, and deliberately not by what a previous sync stored: a
  /// remembered id is wrong the moment the other side opens a different
  /// library, and writing a reading position into the wrong library is worse
  /// than not writing it.
  Future<String?> _libraryIdFor(
    PeerConnection peer,
    FundusRemoteClient client,
    FundusLibrary vault,
  ) async {
    final mirrored = vault
        .listSources()
        .where((source) => source.id == 'peer-${peer.serverId}')
        .firstOrNull;
    if (mirrored != null && mirrored.libraryId.isNotEmpty) {
      return mirrored.libraryId;
    }
    final libraries = await client.libraries();
    for (final candidate in libraries) {
      if (candidate.id == vault.manifest.libraryId) return candidate.id;
    }
    return null;
  }
}
