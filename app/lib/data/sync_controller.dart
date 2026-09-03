import 'package:flutter/foundation.dart';
import 'package:fundus_client/fundus_client.dart';

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
  Future<SyncReport?> syncWith(PeerConnection peer) async {
    final vault = library.library;
    if (vault == null) {
      _failure = 'Es ist keine Bibliothek geöffnet.';
      notifyListeners();
      return null;
    }
    _busy = true;
    _failure = null;
    notifyListeners();

    final client = _connect(peer);
    try {
      final libraryId = await _libraryIdFor(
        peer,
        client,
        vault.manifest.libraryId,
      );
      if (libraryId == null) {
        _failure =
            'Auf „${peer.name}" gibt es diese Bibliothek nicht. Beide Seiten '
            'müssen dieselbe Bibliothek geöffnet haben.';
        _busy = false;
        notifyListeners();
        return null;
      }

      final report = await FundusSync(
        library: vault,
        client: client,
        libraryId: libraryId,
        deviceId: settings.deviceKey,
      ).run();

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

  Future<SyncReport?> syncAll() async {
    SyncReport? last;
    for (final peer in peers) {
      last = await syncWith(peer) ?? last;
    }
    return last;
  }

  /// Which library over there is the one open here.
  ///
  /// Matched by the vault's own id, not by name: two libraries called
  /// „Hörbücher" are not the same library, and the id is what survives being
  /// moved to another drive.
  Future<String?> _libraryIdFor(
    PeerConnection peer,
    FundusRemoteClient client,
    String localLibraryId,
  ) async {
    if (peer.libraryId.isNotEmpty) return peer.libraryId;
    final libraries = await client.libraries();
    for (final candidate in libraries) {
      if (candidate.id == localLibraryId) return candidate.id;
    }
    return null;
  }
}
