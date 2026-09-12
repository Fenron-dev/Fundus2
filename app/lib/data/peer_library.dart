import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_settings.dart';
import '../app/fundus_log.dart';
import 'library_controller.dart';
import 'peer_connection.dart';

/// One paired Fundus, while this device is talking to it.
final class ConnectedPeer {
  ConnectedPeer({
    required this.peer,
    required this.client,
    required this.proxy,
    required this.libraryId,
    required this.sourceId,
    this.libraryName,
    this.lastContactAt,
    this.refused = false,
    this.lastMirror,
  });

  final PeerConnection peer;
  final FundusRemoteClient client;

  /// The loopback door the players fetch this peer's bytes through.
  final FundusStreamProxy proxy;

  /// The library over there that this device mirrors.
  final String libraryId;
  final String? libraryName;

  /// The local shell source row. One server may expose several libraries, so
  /// this is no longer necessarily just `peer-<serverId>`.
  final String sourceId;

  DateTime? lastContactAt;
  bool refused;
  RemoteMirrorReport? lastMirror;

  FundusConnectionState get connection {
    if (refused) return FundusConnectionState.refused;
    final last = lastContactAt;
    if (last == null) return FundusConnectionState.idle;
    return DateTime.now().difference(last) < PeerLibraries.staleAfter
        ? FundusConnectionState.connected
        : FundusConnectionState.idle;
  }

  Future<void> close() async {
    await proxy.close();
    client.close();
  }
}

/// The vault as a place where several Fundus libraries come together.
///
/// A phone has no media of its own and is not going to get any. What it has
/// is a vault that is only an index — a shell — into which every paired
/// machine's catalogue is mirrored, each under a source of its own. From
/// there the whole app works unchanged: one list, one work screen, one
/// progress table, and which machine a work belongs to is a property of the
/// work rather than a mode the app is in.
///
/// Several at once is the normal case, not an exception. Two Macs and a
/// server are three sources in one shell, and the ordinary filter is what
/// separates them again — by machine, by whether it is reachable right now,
/// by whether it was taken along.
///
/// Two things stay on this side and never travel: the bearer token and the
/// pinned certificate. Both live with the pairing, and a player reaches the
/// bytes through the peer's own [FundusStreamProxy].
class PeerLibraries extends ChangeNotifier {
  PeerLibraries({
    required this.settings,
    required this.library,
    FundusRemoteClient Function(PeerConnection peer)? connect,
    Future<Directory> Function()? storageRoot,
  }) : _connect = connect ?? _defaultConnect,
       _storageRoot = storageRoot ?? getApplicationSupportDirectory;

  final AppSettings settings;
  final LibraryController library;
  final FundusRemoteClient Function(PeerConnection peer) _connect;
  final Future<Directory> Function() _storageRoot;

  static FundusRemoteClient _defaultConnect(PeerConnection peer) =>
      FundusRemoteClient(
        baseUri: peer.baseUri,
        token: peer.token,
        certificateFingerprint: peer.certificateFingerprint.isEmpty
            ? null
            : peer.certificateFingerprint,
      );

  /// How often each peer is asked whether it is still there.
  ///
  /// Short enough that the mark means „now" rather than „recently", long
  /// enough that a phone in a pocket is not working all evening. It is also
  /// what keeps this device lit on the *other* side: over there a device
  /// counts as present because its requests keep arriving.
  static const heartbeat = Duration(seconds: 20);

  /// After this long without an answer a mark goes out.
  static const staleAfter = Duration(seconds: 45);

  /// The source id a peer's works are filed under.
  static String sourceIdFor(PeerConnection peer, [String? libraryId]) {
    final id = libraryId?.trim();
    if (id == null || id.isEmpty) return 'peer-${peer.serverId}';
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return 'peer-${peer.serverId}--$safe';
  }

  final Map<String, ConnectedPeer> _connected = {};
  Timer? _pulse;
  bool _busy = false;
  String? _failure;

  List<ConnectedPeer> get connected =>
      _connected.values.toList(growable: false);

  ConnectedPeer? peerFor(String serverId) => _connected.values
      .where((entry) => entry.peer.serverId == serverId)
      .firstOrNull;

  /// The peer a work belongs to, by the source it was mirrored under.
  ConnectedPeer? forSource(String sourceId) => _connected.values
      .where((entry) => entry.sourceId == sourceId)
      .firstOrNull;

  bool get isBusy => _busy;
  String? get failure => _failure;
  bool get hasConnection => _connected.isNotEmpty;

  /// The best of the marks: green while any paired machine answers.
  FundusConnectionState get connection {
    if (_connected.isEmpty) return FundusConnectionState.idle;
    final states = _connected.values.map((entry) => entry.connection);
    if (states.contains(FundusConnectionState.connected)) {
      return FundusConnectionState.connected;
    }
    if (states.every((state) => state == FundusConnectionState.refused)) {
      return FundusConnectionState.refused;
    }
    return FundusConnectionState.idle;
  }

  /// Opens the shell vault, creating it the first time.
  ///
  /// A device that has no library of its own needs one before a catalogue can
  /// be written into it, and asking someone to „create a library" on a phone
  /// that will never hold a file is asking them to understand the plumbing.
  /// So it is made, once, where this installation keeps its own things.
  Future<bool> ensureShellVault() async {
    if (library.isOpen) return true;
    final support = await _storageRoot();
    final room = Directory(p.join(support.path, 'shell'));
    await room.create(recursive: true);
    await library.open(room, createIfMissing: true);
    if (!library.isOpen) {
      _failure = library.error ?? 'Die Bibliothek ließ sich nicht anlegen.';
      notifyListeners();
      return false;
    }
    library.library?.setVaultDisplayName('Meine Werke');
    return true;
  }

  /// Connects to every paired machine and brings its catalogue in.
  ///
  /// Best effort by design: a machine that is switched off is the normal
  /// case, and the others should not wait for it.
  Future<void> connectAll({bool mirror = true}) async {
    if (settings.peers.isEmpty) return;
    _busy = true;
    _failure = null;
    notifyListeners();
    for (final peer in settings.peers) {
      await _open(peer, mirror: mirror);
    }
    _startPulse();
    _busy = false;
    notifyListeners();
  }

  /// Connects to one machine and fetches its catalogue.
  Future<bool> connect(PeerConnection peer, {bool mirror = true}) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    final opened = await _open(peer, mirror: mirror);
    if (opened) _startPulse();
    _busy = false;
    notifyListeners();
    return opened;
  }

  Future<bool> _open(PeerConnection peer, {required bool mirror}) async {
    if (!await ensureShellVault()) return false;
    final vault = library.library;
    if (vault == null) return false;

    final discovery = _connect(peer);
    try {
      final offered = await discovery.libraries();
      if (offered.isEmpty) {
        discovery.close();
        _failure =
            'Auf „${peer.name}" ist gerade keine Bibliothek freigegeben. '
            'Schalte dort die Freigabe ein und öffne eine Bibliothek.';
        return false;
      }

      discovery.close();
      // Reconcile instead of tearing every proxy down. A player may still be
      // reading through an existing loopback proxy, while a newly shared
      // second library must nevertheless be discovered immediately.
      final current = {
        for (final entry in _connected.values)
          if (entry.peer.serverId == peer.serverId) entry.libraryId: entry,
      };
      final offeredIds = {for (final item in offered) item.id};
      for (final entry in current.values.where(
        (entry) => !offeredIds.contains(entry.libraryId),
      )) {
        _connected.remove(entry.sourceId);
        await entry.close();
        vault.setSourceReachable(entry.sourceId, reachable: false);
      }
      final entries = <ConnectedPeer>[];
      for (final offeredLibrary in offered) {
        final existing = current[offeredLibrary.id];
        if (existing != null) {
          existing.lastContactAt = DateTime.now();
          existing.refused = false;
          _connected[existing.sourceId] = existing;
          entries.add(existing);
          vault.setSourceReachable(existing.sourceId, reachable: true);
          continue;
        }
        final client = _connect(peer);
        try {
          final proxy = await FundusStreamProxy.start(
            baseUri: peer.baseUri,
            token: peer.token,
            libraryId: offeredLibrary.id,
            certificateFingerprint: peer.certificateFingerprint.isEmpty
                ? null
                : peer.certificateFingerprint,
          );
          final sourceId = _sourceIdFor(
            vault,
            peer,
            offeredLibrary.id,
            offered.length,
          );
          final entry = ConnectedPeer(
            peer: peer.copyWith(libraryId: offeredLibrary.id),
            client: client,
            proxy: proxy,
            libraryId: offeredLibrary.id,
            libraryName: offeredLibrary.name,
            sourceId: sourceId,
            lastContactAt: DateTime.now(),
          );
          _connected[sourceId] = entry;
          entries.add(entry);
          vault.registerPeerSource(
            sourceId: sourceId,
            displayName: offered.length == 1
                ? peer.name
                : '${peer.name} · ${offeredLibrary.name}',
            libraryId: offeredLibrary.id,
            certificatePin: peer.certificateFingerprint.isEmpty
                ? null
                : peer.certificateFingerprint,
            baseUrl: peer.baseUrl,
          );
          vault.setSourceReachable(sourceId, reachable: true);
        } on Object {
          client.close();
        }
      }
      if (entries.isEmpty) {
        throw const FundusRemoteException(
          'Keine der freigegebenen Bibliotheken konnte geöffnet werden.',
        );
      }
      await settings.savePeer(
        peer.copyWith(libraryId: entries.first.libraryId),
      );
      for (final entry in entries) {
        if (mirror) await _mirror(entry);
      }
      final activeSources = {for (final entry in entries) entry.sourceId};
      for (final source in vault.listSources()) {
        if (source.kind == LibrarySourceKind.peer &&
            source.id.startsWith('peer-${peer.serverId}') &&
            !activeSources.contains(source.id)) {
          vault.setSourceReachable(source.id, reachable: false);
        }
      }
      library.refresh();
      return true;
    } on FundusRemoteException catch (error) {
      discovery.close();
      _failure = error.message;
      _markUnreachable(peer, refused: error.statusCode == 401);
      return false;
    } on Object catch (error) {
      discovery.close();
      _failure = 'Die Verbindung zu „${peer.name}" kam nicht zustande: $error';
      _markUnreachable(peer, refused: false);
      return false;
    }
  }

  /// Fetches the catalogues again, for every machine that answers.
  Future<void> refresh() async {
    _busy = true;
    _failure = null;
    notifyListeners();
    // Asking /libraries again is important: the server's selection and the
    // per-device allow-list can change while the first proxy remains green.
    for (final peer in settings.peers) {
      await _open(peer, mirror: true);
    }
    library.refresh();
    _busy = false;
    notifyListeners();
  }

  Future<void> _mirror(ConnectedPeer entry) async {
    final vault = library.library;
    if (vault == null) return;
    entry.lastMirror = await FundusCatalogueMirror(
      library: vault,
      client: entry.client,
      libraryId: entry.libraryId,
      sourceId: entry.sourceId,
      // Phones should not leave a visible fraction of a novel shelf blank on
      // first connection. The mirror still bounds each pass, while the
      // client-specific value is generous enough for normal libraries.
      coverLimit: 500,
    ).run();
    // Listen gehören der Bibliothek, nicht dem Gerät, auf dem sie entstanden
    // sind — sie reisen mit dem Katalog. Scheitert das, ist der Katalog
    // trotzdem da; eine fehlende Liste ist kein Grund, alles hinzuwerfen.
    try {
      final moved = await FundusPlaylistSync(
        library: vault,
        client: entry.client,
        libraryId: entry.libraryId,
        sourceId: entry.sourceId,
      ).run();
      if (!moved.isEmpty) {
        FundusLog.instance.info('sync.playlists', {
          'geholt': moved.pulled,
          'geschickt': moved.pushed,
          'hier_weg': moved.removedHere,
          'dort_weg': moved.removedThere,
        });
      }
    } on Object catch (error) {
      FundusLog.instance.warn('sync.playlists', {'error': '$error'});
    }
  }

  /// Lets go of one machine. Its works stay in the index — that is what
  /// makes the library readable when nothing answers.
  Future<void> disconnect(String serverId) async {
    final entries = _connected.values
        .where((entry) => entry.peer.serverId == serverId)
        .toList(growable: false);
    for (final entry in entries) {
      _connected.remove(entry.sourceId);
      await entry.close();
      library.library?.setSourceReachable(entry.sourceId, reachable: false);
    }
    library.refresh();
    if (_connected.isEmpty) _stopPulse();
    notifyListeners();
  }

  /// Forgets a machine altogether: the pairing, the connection, and the works
  /// this device only knew about through it.
  Future<void> forget(String serverId) async {
    await disconnect(serverId);
    final sourceIds =
        library.library
            ?.listSources()
            .where(
              (source) =>
                  source.kind == LibrarySourceKind.peer &&
                  source.id.startsWith('peer-$serverId'),
            )
            .map((source) => source.id)
            .toList(growable: false) ??
        const <String>[];
    for (final sourceId in sourceIds) {
      library.library?.dropSource(sourceId);
    }
    await settings.forgetPeer(serverId);
    library.refresh();
    notifyListeners();
  }

  Future<void> closeAll() async {
    _stopPulse();
    for (final entry in _connected.values) {
      await entry.close();
      library.library?.setSourceReachable(entry.sourceId, reachable: false);
    }
    _connected.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPulse();
    for (final entry in _connected.values) {
      unawaited(entry.close());
    }
    super.dispose();
  }

  void _markUnreachable(PeerConnection peer, {required bool refused}) {
    final entries = _connected.values
        .where((entry) => entry.peer.serverId == peer.serverId)
        .toList(growable: false);
    if (entries.isNotEmpty) {
      for (final entry in entries) {
        entry.refused = refused;
        library.library?.setSourceReachable(entry.sourceId, reachable: false);
      }
      // A failed re-open is not proof that the already-running connection is
      // gone. Keep its source available until its own heartbeat goes stale.
      if (entries.any(
        (entry) => entry.connection == FundusConnectionState.connected,
      )) {
        library.refresh();
        return;
      }
    }
    for (final source in library.library?.listSources() ?? const []) {
      if (source.kind == LibrarySourceKind.peer &&
          source.id.startsWith('peer-${peer.serverId}')) {
        library.library?.setSourceReachable(source.id, reachable: false);
      }
    }
    library.refresh();
  }

  /// Asks every connected machine whether it is still there.
  ///
  /// A failure is not worth reporting: a laptop that went to sleep is the
  /// normal case, and the mark going out says it better than a message.
  void _startPulse() {
    _pulse ??= Timer.periodic(heartbeat, (_) async {
      for (final entry in _connected.values.toList()) {
        if (await entry.client.ping()) {
          entry.lastContactAt = DateTime.now();
          entry.refused = false;
          library.library?.setSourceReachable(entry.sourceId, reachable: true);
        } else {
          library.library?.setSourceReachable(entry.sourceId, reachable: false);
        }
      }
      notifyListeners();
    });
  }

  void _stopPulse() {
    _pulse?.cancel();
    _pulse = null;
  }

  static String _sourceIdFor(
    FundusLibrary vault,
    PeerConnection peer,
    String libraryId,
    int offeredCount,
  ) {
    final specific = sourceIdFor(peer, libraryId);
    if (vault.listSources().any((source) => source.id == specific)) {
      return specific;
    }
    final legacy = sourceIdFor(peer);
    if (offeredCount == 1) return legacy;
    final legacySource = vault.listSources().where(
      (source) => source.id == legacy && source.libraryId == libraryId,
    );
    if (legacySource.isNotEmpty) return legacy;
    return specific;
  }
}
