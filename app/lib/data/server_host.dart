import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../app/app_settings.dart';
import '../app/fundus_log.dart';
import 'library_controller.dart';
import 'server_identity.dart';

enum ServerHostState { stopped, starting, running, failed }

/// One library known to the local server, whether it is currently served or
/// only remembered for the next start.
final class ServerLibraryStatus {
  const ServerLibraryStatus({
    required this.path,
    required this.name,
    required this.available,
    required this.shared,
    this.libraryId,
    this.workCount,
    this.error,
  });

  final String path;
  final String name;
  final bool available;
  final bool shared;
  final String? libraryId;
  final int? workCount;
  final String? error;
}

/// Offering this device's library to another Fundus.
///
/// The other half of the sync: something has to answer. Sharing is off until
/// it is switched on, the configured vaults are registered in one server
/// registry. The active vault remains the one shown by the app itself;
/// additional vaults are opened only for serving their own data.
class ServerHostController extends ChangeNotifier {
  ServerHostController({
    required this.settings,
    required this.library,
    ServerIdentityStore? identityStore,
  }) : _identityStore = identityStore {
    _libraries = _statusForPreferences(settings.serverLibraries);
    // Die Freigabe bedient *die* Bibliothek, die offen ist — nicht die, die
    // beim Einschalten offen war. Wird eine andere geöffnet (oder dieselbe
    // erneut, was eine neue Instanz ist), zeigte die Registrierung bisher auf
    // eine geschlossene Datenbank: koppeln ging weiter, alles andere nicht.
    library.addListener(_followLibrary);
  }

  /// The port asked for first. A fixed one makes a pairing code readable and
  /// a firewall rule possible; if it is taken, any free port will do.
  static const preferredPort = 47891;

  final AppSettings settings;
  final LibraryController library;

  ServerIdentityStore? _identityStore;
  ServerIdentity? _identity;

  /// Die Bibliothek, die gerade im Hauptfenster offen ist.
  FundusLibrary? _shared;

  /// Handles opened by this controller for configured, non-active vaults.
  /// The active vault is borrowed from [LibraryController] and never closed
  /// here.
  final Map<String, FundusLibrary> _ownedLibraries = {};

  /// On macOS/iOS the app must restore a security-scoped bookmark before a
  /// remembered additional vault can be opened.
  Future<bool> Function(String path)? unlockPath;

  /// Ob geteilt werden soll, auch wenn gerade keine Bibliothek offen ist.
  bool _wantsSharing = false;
  FundusPairingAuthority? _pairing;
  FundusLibraryRegistry? _registry;
  HttpServer? _socket;
  ServerHostState _state = ServerHostState.stopped;
  String? _failure;
  List<Uri> _addresses = const [];
  Uri? _address;
  List<ServerLibraryStatus> _libraries = const [];
  bool _followingActiveLibrary = false;

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
  List<ServerLibraryStatus> get libraries => List.unmodifiable(_libraries);
  @visibleForTesting
  bool get isReconcilingLibraries => _followingActiveLibrary;

  /// Whether starting can succeed without the currently open vault.
  bool get hasConfiguredLibraries => settings.serverLibraries.isNotEmpty;

  /// A device counts as present while its requests keep arriving.
  ///
  /// The client sends a heartbeat for exactly this, so the mark means „now"
  /// rather than „was here at some point". The window is wider than the
  /// heartbeat interval, because one lost packet is not a disconnection.
  static const presenceWindow = Duration(seconds: 45);

  /// Nothing tells this side that a device *stopped* asking — silence has no
  /// event — so while sharing is on the mark is re-read on a slow tick.
  Timer? _presenceTick;

  FundusConnectionState connectionFor(FundusPairedDevice device) {
    if (!isRunning) return FundusConnectionState.idle;
    final seen = device.lastSeenAt;
    if (seen == null) return FundusConnectionState.idle;
    return DateTime.now().toUtc().difference(seen) < presenceWindow
        ? FundusConnectionState.connected
        : FundusConnectionState.idle;
  }

  /// Whether any paired device is on the line.
  bool get hasConnectedDevice => pairedDevices.any(
    (device) => connectionFor(device) == FundusConnectionState.connected,
  );

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
    // Pairings and their allow-lists belong to the device, not to the
    // currently running socket. Load them even when sharing is switched off,
    // otherwise Settings misleadingly shows no paired devices and offers no
    // way to edit their library permissions until the server is started.
    await _ensureIdentity();
    notifyListeners();
    if (await store.loadSharing()) await start(remember: false);
  }

  Future<void> start({bool remember = true}) async {
    if (isRunning || isBusy) return;
    // Der Wunsch gilt dem Gerät, nicht dem Augenblick: ist gerade keine
    // Bibliothek offen, können die konfigurierten zusätzlichen Bibliotheken
    // trotzdem geöffnet und angeboten werden.
    _wantsSharing = true;
    if (library.library == null &&
        settings.serverLibraries.every((entry) => !entry.enabled)) {
      _failure = 'Es ist keine Bibliothek geöffnet, die sich teilen ließe.';
      notifyListeners();
      return;
    }
    _state = ServerHostState.starting;
    _failure = null;
    notifyListeners();

    try {
      final identity = await _ensureIdentity();
      final registry = FundusLibraryRegistry();
      _registry = registry;
      _libraries = await _registerLibraries(registry);
      if (registry.libraries.isEmpty) {
        throw StateError('Keine der ausgewählten Bibliotheken ist verfügbar.');
      }
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
        // Was das andere Gerät gefragt hat und was es bekam — ohne diese
        // Zeilen ist „bei mir ist nichts erreichbar" nicht nachvollziehbar.
        requestObserver: _logRequest,
      );
      _socket = await _listen(handler, identity);
      _addresses = await _networkAddresses(_socket!.port);
      _address = _addresses.firstOrNull;
      _state = ServerHostState.running;
      FundusLog.instance.info('server.start', {
        'port': _socket!.port,
        'libraries': registry.libraries.length,
        'configured': _libraries.length,
      });
      for (final item in _libraries) {
        FundusLog.instance.write(
          item.error == null ? LogLevel.info : LogLevel.warn,
          'server.library',
          {
            'name': item.name,
            'shared': item.shared,
            'available': item.available,
            if (item.libraryId != null) 'id': item.libraryId,
            if (item.error != null) 'error': item.error,
          },
        );
      }
      if (remember) await _identityStore!.saveSharing(true);
      _presenceTick ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => notifyListeners(),
      );
    } on Object catch (error) {
      await _closeSocket();
      _releaseRegistry();
      _failure = _describe(error);
      _state = ServerHostState.failed;
    }
    notifyListeners();
  }

  /// Adds a vault to the server's persistent sharing selection. The currently
  /// open vault is copied into the selection the first time an extra vault is
  /// added, so the old one-library behaviour stays visible without another
  /// setting having to be understood.
  Future<void> addLibrary(String path, {String? name}) async {
    final normalized = Directory(path).absolute.path;
    final current = library.library;
    final existing = [...settings.serverLibraries];
    if (existing.isEmpty && current != null) {
      existing.add(
        ServerLibraryPreference(
          path: current.root.absolute.path,
          name: library.displayName,
        ),
      );
    }
    final index = existing.indexWhere(
      (entry) => Directory(entry.path).absolute.path == normalized,
    );
    final replacement = ServerLibraryPreference(
      path: normalized,
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : index >= 0
          ? existing[index].name
          : p.basename(normalized),
    );
    if (index >= 0) {
      existing[index] = replacement;
    } else {
      existing.add(replacement);
    }
    await settings.setServerLibraries(existing);
    if (isRunning) {
      await _restartAfterLibraryChange();
    } else {
      _libraries = _statusForPreferences(existing);
      notifyListeners();
    }
  }

  /// Removes a non-active vault from the sharing selection.
  Future<void> removeLibrary(String path) async {
    final normalized = Directory(path).absolute.path;
    final remaining = settings.serverLibraries
        .where((entry) => Directory(entry.path).absolute.path != normalized)
        .toList(growable: false);
    await settings.setServerLibraries(remaining);
    if (isRunning) {
      await _restartAfterLibraryChange();
    } else {
      _libraries = _statusForPreferences(remaining);
      notifyListeners();
    }
  }

  /// Enables or disables one configured vault without forgetting its path.
  Future<void> setLibraryShared(String path, bool shared) async {
    final normalized = Directory(path).absolute.path;
    final values = [...settings.serverLibraries];
    if (values.isEmpty && library.library != null) {
      values.add(
        ServerLibraryPreference(
          path: library.library!.root.absolute.path,
          name: library.displayName,
        ),
      );
    }
    final index = values.indexWhere(
      (entry) => Directory(entry.path).absolute.path == normalized,
    );
    if (index < 0) {
      values.add(
        ServerLibraryPreference(
          path: normalized,
          name: p.basename(normalized),
          enabled: shared,
        ),
      );
    } else {
      final current = values[index];
      values[index] = ServerLibraryPreference(
        path: current.path,
        name: current.name,
        enabled: shared,
      );
    }
    await settings.setServerLibraries(values);
    if (isRunning) {
      await _restartAfterLibraryChange();
    } else {
      _libraries = _statusForPreferences(values);
      notifyListeners();
    }
  }

  List<ServerLibraryPreference> _sourcesToServe() {
    final configured = settings.serverLibraries;
    if (configured.isNotEmpty) return configured;
    final active = library.library;
    if (active == null) return const [];
    return [
      ServerLibraryPreference(
        path: active.root.absolute.path,
        name: library.displayName,
      ),
    ];
  }

  Future<List<ServerLibraryStatus>> _registerLibraries(
    FundusLibraryRegistry registry,
  ) async {
    final statuses = <ServerLibraryStatus>[];
    final seen = <String>{};
    final active = library.library;
    _shared = null;
    for (final source in _sourcesToServe()) {
      final path = Directory(source.path).absolute.path;
      if (!seen.add(path)) continue;
      if (!source.enabled) {
        statuses.add(
          ServerLibraryStatus(
            path: path,
            name: source.name,
            available: await Directory(path).exists(),
            shared: false,
          ),
        );
        continue;
      }
      if (active != null && active.root.absolute.path == path) {
        registry.register(active, name: source.name);
        _shared = active;
        statuses.add(
          ServerLibraryStatus(
            path: path,
            name: source.name,
            available: true,
            shared: true,
            libraryId: active.manifest.libraryId,
            workCount: active.listWorks().length,
          ),
        );
        continue;
      }
      final alreadyOpen = _ownedLibraries[path];
      if (alreadyOpen != null) {
        registry.register(alreadyOpen, name: source.name);
        final shared = registry.lookup(alreadyOpen.manifest.libraryId)!;
        statuses.add(
          ServerLibraryStatus(
            path: path,
            name: source.name,
            available: true,
            shared: true,
            libraryId: alreadyOpen.manifest.libraryId,
            workCount: shared.works.length,
          ),
        );
        continue;
      }
      try {
        if (unlockPath != null) await unlockPath!(path);
        final opened = await FundusLibrary.open(
          Directory(path),
        ).timeout(LibraryController.reachTimeout);
        _ownedLibraries[path] = opened;
        registry.register(opened, name: source.name);
        final shared = registry.lookup(opened.manifest.libraryId)!;
        statuses.add(
          ServerLibraryStatus(
            path: path,
            name: source.name,
            available: true,
            shared: true,
            libraryId: opened.manifest.libraryId,
            workCount: shared.works.length,
          ),
        );
      } on Object catch (error) {
        statuses.add(
          ServerLibraryStatus(
            path: path,
            name: source.name,
            available: false,
            shared: true,
            error: _libraryError(error),
          ),
        );
      }
    }
    return statuses;
  }

  List<ServerLibraryStatus> _statusForPreferences(
    List<ServerLibraryPreference> values,
  ) {
    final sources = values.isEmpty ? _sourcesToServe() : values;
    return [
      for (final source in sources)
        ServerLibraryStatus(
          path: Directory(source.path).absolute.path,
          name: source.name,
          available: Directory(source.path).existsSync(),
          shared: source.enabled,
        ),
    ];
  }

  static String _libraryError(Object error) => error is FileSystemException
      ? error.message
      : 'Bibliothek konnte nicht geöffnet werden.';

  Future<void> _restartAfterLibraryChange() async {
    if (!isRunning) return;
    await _closeSocket();
    _releaseRegistry();
    _pairing?.cancel();
    _state = ServerHostState.stopped;
    _addresses = const [];
    _address = null;
    await start(remember: false);
  }

  Future<void> stop({bool remember = true}) async {
    _wantsSharing = false;
    _shared = null;
    _presenceTick?.cancel();
    _presenceTick = null;
    await _closeSocket();
    _releaseRegistry();
    _pairing?.cancel();
    _addresses = const [];
    _address = null;
    _state = ServerHostState.stopped;
    _failure = null;
    _libraries = _statusForPreferences(settings.serverLibraries);
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

  /// Restricts one paired device to the selected shared libraries. `null`
  /// restores the legacy behaviour where every shared library is visible.
  Future<void> setDeviceLibraries(
    String deviceId,
    Set<String>? libraryIds,
  ) async {
    await _pairing?.setAllowedLibraries(deviceId, libraryIds);
    notifyListeners();
  }

  Future<void> setDeviceAdultExplicit(String deviceId, bool allowed) async {
    await _pairing?.setAdultExplicitAllowed(deviceId, allowed);
    notifyListeners();
  }

  @override
  void dispose() {
    library.removeListener(_followLibrary);
    _presenceTick?.cancel();
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close(force: true));
    _releaseRegistry();
    super.dispose();
  }

  /// Hält die Freigabe auf der Bibliothek, die gerade offen ist.
  ///
  /// `LibraryController.open` legt jedes Mal eine neue Instanz an und
  /// schließt die alte. Die Registrierung zeigte danach auf eine
  /// geschlossene Datenbank — von außen sah das so aus: koppeln geht,
  /// „verbunden" blinkt kurz auf, und erreichbar ist nichts.
  void _followLibrary() {
    final vault = library.library;
    if (identical(vault, _shared)) {
      // Dieselbe Bibliothek, aber ihr Inhalt ändert sich: ein Scan, eine
      // geänderte Angabe, ein neues Werk. Der Abzug, den die Freigabe hält,
      // gilt damit nicht mehr — gelesen wird er erst, wenn jemand fragt.
      for (final shared in _registry?.libraries ?? const []) {
        shared.invalidate();
      }
      return;
    }
    if (_state == ServerHostState.running) {
      // The former active vault was borrowed and LibraryController has just
      // closed it. Reconcile all selected paths so the new active vault is
      // borrowed and the old active one is reopened as a background handle.
      unawaited(_followActiveLibraryChange());
      return;
    }
    // Eingeschaltet, aber beim Einschalten war nichts offen: sobald eine
    // Bibliothek da ist, geht die Freigabe von selbst an.
    if (_wantsSharing && vault != null && _state != ServerHostState.starting) {
      unawaited(start(remember: false));
    }
  }

  Future<void> _followActiveLibraryChange() async {
    if (_followingActiveLibrary) return;
    _followingActiveLibrary = true;
    try {
      if (_state == ServerHostState.running) {
        final registry = _registry;
        if (registry == null) return;
        FundusLog.instance.info('server.library', {
          'library': library.library == null ? 'keine' : library.displayName,
          'action': 'registry_reconcile',
        });
        final formerActive = _shared;
        if (formerActive != null) {
          registry.unregister(formerActive.manifest.libraryId);
        }
        _shared = null;
        final activePath = library.library?.root.absolute.path;
        if (activePath != null) {
          _ownedLibraries.remove(activePath)?.close();
        }
        _libraries = await _registerLibraries(registry);
        if (registry.libraries.isEmpty) {
          _failure = 'Keine der ausgewählten Bibliotheken ist verfügbar.';
        } else {
          _failure = null;
        }
        notifyListeners();
      }
    } finally {
      _followingActiveLibrary = false;
    }
  }

  /// Schreibt mit, was ein gekoppeltes Gerät gefragt hat.
  ///
  /// Erfolgreiche Dateiabrufe wären ein Wasserfall — ein Comic sind hundert
  /// Seiten —, deshalb steht davon nur die Art im Protokoll, und jeder
  /// Fehlschlag vollständig.
  void _logRequest(FundusServerRequestEvent event) {
    final failed = event.statusCode >= 400;
    FundusLog.instance.write(
      failed ? LogLevel.warn : LogLevel.debug,
      'server.request',
      {
        'method': event.method,
        'was': event.resource,
        'antwort': event.statusCode,
      },
    );
    if (!failed) _followWrite(event);
  }

  /// Was ein gekoppeltes Gerät hierher geschrieben hat, steht danach auch auf
  /// dem Bildschirm.
  ///
  /// Der Server schreibt in dieselbe Bibliothek, die hier offen ist — nur
  /// wusste die Oberfläche nichts davon. Ein Lesestand vom Handy kam an und
  /// war trotzdem nicht zu sehen, bis jemand von Hand aufgefrischt hat.
  void _followWrite(FundusServerRequestEvent event) {
    if (event.method == 'GET' || event.method == 'HEAD') return;
    const watched = {'progress', 'annotations'};
    if (!watched.contains(event.resource)) return;
    final workId = event.workId;
    if (workId == null) return;
    library.refreshWork(workId);
  }

  /// Lets go of the shared library without closing it.
  ///
  /// `FundusLibraryRegistry.close()` closes every library it holds, which is
  /// right when the registry opened them. Here it did not: this is the vault
  /// the person has open, and switching sharing off must not take their
  /// library down with it.
  void _releaseRegistry() {
    _shared = null;
    final registry = _registry;
    _registry = null;
    if (registry != null) {
      for (final shared in registry.libraries) {
        registry.unregister(shared.id);
      }
    }
    for (final owned in _ownedLibraries.values) {
      owned.close();
    }
    _ownedLibraries.clear();
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
