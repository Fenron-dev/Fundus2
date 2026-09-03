import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../app/app_settings.dart';
import 'library_controller.dart';
import 'server_identity.dart';

enum ServerHostState { stopped, starting, running, failed }

/// Offering this device's library to another Fundus.
///
/// The other half of the sync: something has to answer. Sharing is off until
/// it is switched on, and while it is on the vault that is open here is the
/// one that is served — one library, the one in front of the person, rather
/// than a second list of folders to keep in step with the first.
class ServerHostController extends ChangeNotifier {
  ServerHostController({
    required this.settings,
    required this.library,
    ServerIdentityStore? identityStore,
  }) : _identityStore = identityStore;

  /// The port asked for first. A fixed one makes a pairing code readable and
  /// a firewall rule possible; if it is taken, any free port will do.
  static const preferredPort = 47891;

  final AppSettings settings;
  final LibraryController library;

  ServerIdentityStore? _identityStore;
  ServerIdentity? _identity;
  FundusPairingAuthority? _pairing;
  FundusLibraryRegistry? _registry;
  HttpServer? _socket;
  ServerHostState _state = ServerHostState.stopped;
  String? _failure;
  List<Uri> _addresses = const [];
  Uri? _address;

  ServerHostState get state => _state;
  bool get isRunning => _state == ServerHostState.running;
  bool get isBusy => _state == ServerHostState.starting;
  String? get failure => _failure;
  String get serverId => _identity?.serverId ?? '';

  /// Every address this machine can be reached at. More than one is normal —
  /// cable and wireless are two ways to the same Fundus — so the person picks
  /// the one the other device can see.
  List<Uri> get addresses => List.unmodifiable(_addresses);
  Uri? get address => _address;

  FundusPairingSession? get pairingSession => _pairing?.activeSession;
  List<FundusPairedDevice> get pairedDevices => _pairing?.devices ?? const [];

  /// The code the other device reads: where, who, which certificate, and a
  /// nonce that is only good for the next few minutes.
  ///
  /// The PIN is deliberately *not* in it. A code that travels as a photo or
  /// a message is a code that can be copied; the six digits shown beside it
  /// have to be read off this screen, which is the part that says the person
  /// is standing here.
  String? get pairingCode {
    final session = pairingSession;
    final identity = _identity;
    final address = _address;
    if (session == null || identity == null || address == null) return null;
    return jsonEncode({
      'type': 'fundus_pairing',
      'version': 1,
      'base_url': address.toString(),
      'server_id': identity.serverId,
      'server_name': settings.deviceName,
      'certificate_sha256': identity.certificateFingerprint,
      'nonce': session.nonce,
      'expires_at': session.expiresAt.toUtc().toIso8601String(),
    });
  }

  /// Starts again if it was running when the app was last closed.
  Future<void> restore() async {
    final store = _identityStore ??=
        await ServerIdentityStore.platformDefault();
    if (await store.loadSharing()) await start(remember: false);
  }

  Future<void> start({bool remember = true}) async {
    if (isRunning || isBusy) return;
    final vault = library.library;
    if (vault == null) {
      _failure = 'Es ist keine Bibliothek geöffnet, die sich teilen ließe.';
      notifyListeners();
      return;
    }
    _state = ServerHostState.starting;
    _failure = null;
    notifyListeners();

    try {
      final identity = await _ensureIdentity();
      // The registry only borrows the open vault. Closing it is the app's
      // business, not the server's — see [_releaseRegistry].
      final registry = FundusLibraryRegistry()
        ..register(vault, name: library.displayName);
      _registry = registry;
      final handler = FundusServerHandler(
        // Only paired devices get in. The handler also accepts one fixed
        // token; it is generated here, never shown and never stored, so no
        // request can carry it — an empty one would be guessable, and the
        // fixed token skips the per-device rules.
        token: _unusedToken(),
        serverId: identity.serverId,
        serverName: settings.deviceName,
        registry: registry,
        pairingAuthority: _pairing,
      );
      _socket = await _listen(handler, identity);
      _addresses = await _networkAddresses(_socket!.port);
      _address = _addresses.firstOrNull;
      _state = ServerHostState.running;
      if (remember) await _identityStore!.saveSharing(true);
    } on Object catch (error) {
      await _closeSocket();
      _releaseRegistry();
      _failure = _describe(error);
      _state = ServerHostState.failed;
    }
    notifyListeners();
  }

  Future<void> stop({bool remember = true}) async {
    await _closeSocket();
    _releaseRegistry();
    _pairing?.cancel();
    _addresses = const [];
    _address = null;
    _state = ServerHostState.stopped;
    _failure = null;
    if (remember) await _identityStore?.saveSharing(false);
    notifyListeners();
  }

  Future<void> setSharing(bool value) => value ? start() : stop();

  /// Chooses which address the code should name.
  void useAddress(Uri value) {
    if (!_addresses.contains(value) || _address == value) return;
    _address = value;
    // The code carries the address, so a different address is a different
    // code — the one on screen must never point somewhere it no longer does.
    _pairing?.cancel();
    notifyListeners();
  }

  /// Opens a pairing window. It closes by itself after a few minutes.
  void beginPairing() {
    if (!isRunning || _address == null) return;
    _pairing?.begin();
    notifyListeners();
  }

  void cancelPairing() {
    _pairing?.cancel();
    notifyListeners();
  }

  Future<void> revoke(String deviceId) async {
    await _pairing?.revoke(deviceId);
    notifyListeners();
  }

  @override
  void dispose() {
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close(force: true));
    _releaseRegistry();
    super.dispose();
  }

  /// Lets go of the shared library without closing it.
  ///
  /// `FundusLibraryRegistry.close()` closes every library it holds, which is
  /// right when the registry opened them. Here it did not: this is the vault
  /// the person has open, and switching sharing off must not take their
  /// library down with it.
  void _releaseRegistry() {
    final registry = _registry;
    _registry = null;
    if (registry == null) return;
    for (final shared in registry.libraries) {
      registry.unregister(shared.id);
    }
  }

  Future<ServerIdentity> _ensureIdentity() async {
    final store = _identityStore ??=
        await ServerIdentityStore.platformDefault();
    final existing = _identity;
    if (existing != null && _pairing != null) return existing;
    // Making an RSA key blocks for a moment, so it happens off the interface
    // thread; the result is written once and read back on every later start.
    final identity = await store.loadOrCreate();
    _identity = identity;
    _pairing = FundusPairingAuthority(
      devices: identity.pairedDevices,
      onChanged: (devices) async {
        await store.savePairedDevices(devices);
        notifyListeners();
      },
    );
    return identity;
  }

  Future<HttpServer> _listen(
    FundusServerHandler handler,
    ServerIdentity identity,
  ) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    try {
      return await shelf_io.serve(
        handler.handler,
        InternetAddress.anyIPv4,
        preferredPort,
        securityContext: context,
      );
    } on SocketException {
      // The preferred port is a convenience, not a requirement.
      return shelf_io.serve(
        handler.handler,
        InternetAddress.anyIPv4,
        0,
        securityContext: context,
      );
    }
  }

  Future<void> _closeSocket() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close(force: true);
  }

  static Future<List<Uri>> _networkAddresses(int port) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final found = <Uri>[
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && !address.isLinkLocal)
            Uri(scheme: 'https', host: address.address, port: port),
    ];
    found.sort((a, b) => a.host.compareTo(b.host));
    return found;
  }

  /// A token nobody has. See where it is used.
  static String _unusedToken() => base64UrlEncode(
    List<int>.generate(32, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  static final _random = Random.secure();

  static String _describe(Object error) => switch (error) {
    SocketException() when Platform.isMacOS =>
      'macOS hat den Netzwerkzugriff abgelehnt. Erlaube Fundus in den '
          'Systemeinstellungen eingehende Verbindungen.',
    SocketException() => 'Der Port ließ sich nicht öffnen.',
    FileSystemException() =>
      'Der Serverschlüssel ließ sich nicht lesen oder anlegen.',
    _ => 'Die Freigabe ist fehlgeschlagen: $error',
  };
}
