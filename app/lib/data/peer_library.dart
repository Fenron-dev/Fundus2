import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app/app_settings.dart';
import 'library_controller.dart';
import 'peer_connection.dart';

/// Opening the library of a Fundus this device is paired with.
///
/// A phone has no media of its own and is not going to get any. What it can
/// have is a vault that is only an index: the works of the paired machine
/// mirrored into the ordinary tables, and the reading state that belongs to
/// this device kept in the ordinary sidecars. From there the whole app works
/// unchanged — the same list, the same work screen, the same progress — and
/// "remote" is a column rather than a second application.
///
/// Two things stay on this side and never travel: the bearer token and the
/// pinned certificate. Both live with the pairing, and the player reaches the
/// bytes through [FundusStreamProxy], which is the only thing that holds
/// them.
class PeerLibraryController extends ChangeNotifier {
  PeerLibraryController({
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

  /// How often the peer is asked whether it is still there.
  ///
  /// Short enough that the mark means "now" rather than "recently", long
  /// enough that a phone in a pocket is not doing work all evening. It is
  /// also what keeps this device lit on the *other* side: over there a device
  /// counts as present because its requests keep arriving.
  static const heartbeat = Duration(seconds: 20);

  /// After this long without an answer the mark goes out.
  static const _staleAfter = Duration(seconds: 45);

  Timer? _pulse;
  DateTime? _lastContactAt;
  bool _refused = false;

  PeerConnection? _peer;
  FundusRemoteClient? _client;
  FundusStreamProxy? _proxy;
  String? _failure;
  bool _busy = false;
  RemoteMirrorReport? _lastMirror;

  /// The peer whose library is open, if one is.
  PeerConnection? get peer => _peer;

  /// Where a player fetches remote bytes. Null while no peer is open.
  FundusStreamProxy? get proxy => _proxy;

  /// The open connection, for the things that fetch bytes themselves rather
  /// than through the player's proxy — a comic's pages, a cover.
  FundusRemoteClient? get client => _client;

  bool get isBusy => _busy;

  /// Whether the peer answered a moment ago.
  FundusConnectionState get connection {
    if (_peer == null) return FundusConnectionState.idle;
    if (_refused) return FundusConnectionState.refused;
    final last = _lastContactAt;
    if (last == null) return FundusConnectionState.idle;
    return DateTime.now().difference(last) < _staleAfter
        ? FundusConnectionState.connected
        : FundusConnectionState.idle;
  }

  DateTime? get lastContactAt => _lastContactAt;

  String? get failure => _failure;
  RemoteMirrorReport? get lastMirror => _lastMirror;
  bool get isOpen => _peer != null;

  /// The source id a peer's works are filed under in the local index.
  static String sourceIdFor(PeerConnection peer) => 'peer-${peer.serverId}';

  /// Opens the peer's library: index here, files over there.
  Future<bool> open(PeerConnection peer) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final root = await _vaultFor(peer);
      await library.open(root, createIfMissing: true);
      final vault = library.library;
      if (vault == null) {
        _failure = library.error ?? 'Die Bibliothek ließ sich nicht anlegen.';
        return _done(false);
      }

      final client = _connect(peer);
      final libraryId = await _libraryIdFor(peer, client);
      if (libraryId == null) {
        client.close();
        _failure =
            'Auf „${peer.name}" ist gerade keine Bibliothek freigegeben. '
            'Schalte dort die Freigabe ein und öffne eine Bibliothek.';
        return _done(false);
      }

      final sourceId = sourceIdFor(peer);
      vault.registerPeerSource(
        sourceId: sourceId,
        displayName: peer.name,
        libraryId: libraryId,
        baseUrl: peer.baseUrl,
        certificatePin: peer.certificateFingerprint.isEmpty
            ? null
            : peer.certificateFingerprint,
      );

      _lastMirror = await FundusCatalogueMirror(
        library: vault,
        client: client,
        libraryId: libraryId,
        sourceId: sourceId,
      ).run();

      await _proxy?.close();
      _proxy = await FundusStreamProxy.start(
        baseUri: peer.baseUri,
        token: peer.token,
        libraryId: libraryId,
        certificateFingerprint: peer.certificateFingerprint.isEmpty
            ? null
            : peer.certificateFingerprint,
      );

      // The vault is called what the machine is called; the folder it sits
      // in is an implementation detail nobody asked to see.
      vault.setVaultDisplayName(peer.name);

      _client?.close();
      _client = client;
      _peer = peer.copyWith(libraryId: libraryId);
      _lastContactAt = DateTime.now();
      _refused = false;
      _startPulse();
      // Remembered so the sync knows which library over there answers for
      // this one without asking again.
      await settings.savePeer(_peer!);
      library.refresh();
      return _done(true);
    } on FundusRemoteException catch (error) {
      _failure = error.message;
    } on Object catch (error) {
      _failure = 'Die Bibliothek ließ sich nicht öffnen: $error';
    }
    return _done(false);
  }

  /// Fetches the catalogue again — after a scan on the other machine, or when
  /// a work is missing here that is plainly there.
  Future<bool> refresh() async {
    final peer = _peer;
    final client = _client;
    final vault = library.library;
    if (peer == null || client == null || vault == null) return false;
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      _lastMirror = await FundusCatalogueMirror(
        library: vault,
        client: client,
        libraryId: peer.libraryId,
        sourceId: sourceIdFor(peer),
      ).run();
      vault.setSourceReachable(sourceIdFor(peer), reachable: true);
      _lastContactAt = DateTime.now();
      _refused = false;
      library.refresh();
      return _done(true);
    } on FundusRemoteException catch (error) {
      // The works stay where they are; only their origin says the machine is
      // not answering. A library that empties itself because a laptop went to
      // sleep would be worse than useless.
      vault.setSourceReachable(sourceIdFor(peer), reachable: false);
      // A refusal is a different thing from silence: a revoked device or a
      // changed certificate will not fix itself by waiting.
      _refused = error.statusCode == 401 || error.statusCode == 403;
      library.refresh();
      _failure = error.message;
    } on Object catch (error) {
      _failure = 'Der Katalog ließ sich nicht holen: $error';
    }
    return _done(false);
  }

  /// Asks the peer whether it is still there, and lets both sides know.
  ///
  /// A failure is not an error to report: a laptop that went to sleep is the
  /// normal case, and the mark going out says it better than a message would.
  void _startPulse() {
    _pulse?.cancel();
    _pulse = Timer.periodic(heartbeat, (_) async {
      final client = _client;
      if (client == null) return;
      final reachable = await client.ping();
      if (reachable) {
        _lastContactAt = DateTime.now();
        _refused = false;
      }
      notifyListeners();
    });
  }

  /// Lets go of the peer. The mirrored index stays on disk — it is what makes
  /// the library readable again before the network answers.
  Future<void> close() async {
    _pulse?.cancel();
    _pulse = null;
    _lastContactAt = null;
    await _proxy?.close();
    _proxy = null;
    _client?.close();
    _client = null;
    _peer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _pulse?.cancel();
    _proxy?.close();
    _client?.close();
    super.dispose();
  }

  bool _done(bool value) {
    _busy = false;
    notifyListeners();
    return value;
  }

  Future<String?> _libraryIdFor(
    PeerConnection peer,
    FundusRemoteClient client,
  ) async {
    final libraries = await client.libraries();
    if (libraries.isEmpty) return null;
    if (peer.libraryId.isNotEmpty &&
        libraries.any((entry) => entry.id == peer.libraryId)) {
      return peer.libraryId;
    }
    return libraries.first.id;
  }

  /// One index per peer, beside the app's own settings.
  ///
  /// Not in the media folders: it holds no media. It is a database and a set
  /// of sidecars, and it belongs where the rest of this installation's state
  /// lives.
  Future<Directory> _vaultFor(PeerConnection peer) async {
    final support = await _storageRoot();
    final directory = Directory(
      p.join(support.path, 'peers', _safeName(peer.serverId)),
    );
    await directory.create(recursive: true);
    return directory;
  }

  static String _safeName(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
