import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/library_controller.dart';
import '../data/server_host.dart';
import '../data/peer_connection.dart';
import '../data/download_controller.dart';
import '../data/peer_library.dart';
import '../data/protection.dart';
import '../data/sync_controller.dart';
import '../data/work_filter.dart';
import '../data/work_view.dart';
import '../media/capture.dart';
import '../media/peer_file_cache.dart';
import '../media/photo_controller.dart';
import '../media/playback_preference.dart';
import '../media/remote_comic_source.dart';
import '../media/track_preference.dart';
import '../media/playback_controller.dart';
import '../media/reader_controller.dart';
import '../media/text_reader_controller.dart';
import 'app_navigation.dart';
import 'fullscreen.dart';
import 'pairing_scanner.dart';
import 'storage_access.dart';
import 'app_settings.dart';

/// The app's shared state, handed down once instead of threaded through every
/// constructor.
class FundusScope extends StatefulWidget {
  const FundusScope({
    super.key,
    required this.settings,
    required this.library,
    required this.child,
    this.player,
    this.reader,
    this.textReader,
    this.fullscreen,
    this.sync,
    this.host,
    this.peerLibraries,
    this.downloads,
    this.photos,
    this.protection,
    this.supportRoot,
    this.captureSink = const FileCaptureSink(),
    this.storage = const PlatformStorageAccess(),
    this.scanner = const CameraPairingScanner(),
  });

  final AppSettings settings;
  final LibraryController library;

  /// Supplied by tests with a stand-in engine; the app builds its own.
  final PlaybackController? player;

  /// Same for the page reader.
  final ReaderController? reader;

  /// And for the text reader.
  final TextReaderController? textReader;

  /// And for the window: a test must not ask the window manager for anything.
  final FullscreenController? fullscreen;

  /// And for the sync, so a test never reaches for the network.
  final SyncController? sync;

  /// And for the served side, so a test never opens a port.
  final ServerHostController? host;

  /// And for the paired machines, so a test never reaches for one.
  final PeerLibraries? peerLibraries;

  /// And for downloads, so a test never writes into app storage.
  final DownloadController? downloads;

  /// And for the gallery.
  final PhotoController? photos;

  /// And for the protected shelf.
  final ProtectionController? protection;

  /// Where fetched copies are kept. Supplied by a test; the app asks the
  /// platform.
  final Directory? supportRoot;

  /// Where a saved page or frame goes. The default opens a system dialog.
  final CaptureSink captureSink;

  /// Whether the device lets the app read its files. Only Android asks.
  final StorageAccess storage;

  /// How a pairing code is read off the other screen. The default opens the
  /// camera, which a test has none of.
  final PairingScanner scanner;
  final Widget child;

  static FundusScopeState of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_FundusScopeMarker>();
    assert(scope != null, 'FundusScope fehlt über diesem Widget.');
    return scope!.state;
  }

  @override
  State<FundusScope> createState() => FundusScopeState();
}

class FundusScopeState extends State<FundusScope> {
  final navigation = AppNavigation();
  late final PlaybackController player =
      widget.player ?? PlaybackController(deviceId: widget.settings.deviceKey);
  late final ReaderController reader =
      widget.reader ?? ReaderController(deviceId: widget.settings.deviceKey);
  late final TextReaderController textReader =
      widget.textReader ??
      TextReaderController(deviceId: widget.settings.deviceKey);
  late final FullscreenController fullscreen =
      widget.fullscreen ?? FullscreenController();
  late final SyncController sync =
      widget.sync ??
      SyncController(settings: widget.settings, library: widget.library);
  late final ServerHostController host =
      widget.host ??
      ServerHostController(settings: widget.settings, library: widget.library);
  late final PeerLibraries peerLibraries =
      widget.peerLibraries ??
      PeerLibraries(settings: widget.settings, library: widget.library);
  late final PhotoController photos = widget.photos ?? PhotoController();
  late final ProtectionController protection =
      widget.protection ?? ProtectionController(settings: widget.settings);
  late final DownloadController downloads =
      widget.downloads ??
      DownloadController(
        library: widget.library,
        storageRoot: getApplicationSupportDirectory,
      );
  WorkFilter _filter = const WorkFilter();
  int _revision = 0;

  AppSettings get settings => widget.settings;
  CaptureSink get captureSink => widget.captureSink;
  StorageAccess get storage => widget.storage;
  PairingScanner get scanner => widget.scanner;
  LibraryController get library => widget.library;
  WorkFilter get filter => _filter;

  @override
  void initState() {
    super.initState();
    navigation.addListener(_bump);
    settings.addListener(_bump);
    library.addListener(_bump);
    player.addListener(_bump);
    reader.addListener(_bump);
    textReader.addListener(_bump);
    fullscreen.addListener(_bump);
    sync.addListener(_bump);
    host.addListener(_bump);
    peerLibraries.addListener(_bump);
    downloads.addListener(_bump);
    photos.addListener(_bump);
    protection.addListener(_applyProtection);
    library.hides = protection.hides;
    peerLibraries.addListener(_wireSources);
    player.addListener(_syncWhenClosed);
    reader.addListener(_syncWhenClosed);
    textReader.addListener(_syncWhenClosed);
    unawaited(_findSupportRoot());
  }

  /// Where this installation keeps its own things.
  ///
  /// Asked once at the start, because the places that need it — a reader
  /// about to fetch a volume — cannot wait for an answer. Without it there is
  /// nowhere to put a fetched file, and the readers say so; without *asking*
  /// for it they say so wrongly, which is what happened.
  Future<void> _findSupportRoot() async {
    if (widget.supportRoot != null) {
      _supportRoot = widget.supportRoot;
      _wireSources();
      return;
    }
    try {
      _supportRoot = await getApplicationSupportDirectory();
    } on Object {
      // A platform that will not say where its storage is must not cost the
      // ability to read: somewhere temporary is worse than the right place
      // and far better than nowhere.
      _supportRoot = Directory.systemTemp.createTempSync('fundus-');
    }
    _wireSources();
  }

  /// Where each player and reader gets its bytes.
  ///
  /// A work belongs to a source, and the source says which machine holds its
  /// files. Nothing above this asks who that is: they are handed a way to
  /// look it up, and get null for a work that lies on this disk — which is
  /// exactly what „local" means to a player.
  void _wireSources() {
    FundusStreamProxy? proxyFor(String sourceId) =>
        peerLibraries.forSource(sourceId)?.proxy;

    PeerFileCache? cacheFor(String sourceId) {
      final room = _supportRoot;
      final entry = peerLibraries.forSource(sourceId);
      if (room == null || entry == null) return null;
      return PeerFileCache(
        proxy: entry.proxy,
        directory: Directory(
          p.join(room.path, 'peer-cache', entry.peer.serverId),
        ),
      );
    }

    player.proxyForSource = proxyFor;
    downloads.proxyForSource = proxyFor;
    reader.cacheForSource = cacheFor;
    textReader.cacheForSource = cacheFor;
    photos.cacheForSource = cacheFor;

    // A comic is paged rather than fetched whole, so the reader is given a
    // way to open one against the connection it belongs to.
    reader.remotePages = (volume) {
      final room = _supportRoot;
      final entry = peerLibraries.forSource(volume.sourceId);
      if (room == null || entry == null) return null;
      return RemoteComicPageSource(
        client: entry.client,
        libraryId: entry.libraryId,
        fileId: volume.fileId,
        name: volume.title,
        cacheDirectory: Directory(
          p.join(room.path, 'peer-cache', entry.peer.serverId, 'pages'),
        ),
      );
    };
  }

  /// Where this installation keeps its own things. Read once, because the
  /// places that need it cannot wait for an answer.
  Directory? _supportRoot;

  @override
  void dispose() {
    navigation.removeListener(_bump);
    settings.removeListener(_bump);
    library.removeListener(_bump);
    player.removeListener(_bump);
    reader.removeListener(_bump);
    textReader.removeListener(_bump);
    fullscreen.removeListener(_bump);
    sync.removeListener(_bump);
    host.removeListener(_bump);
    peerLibraries.removeListener(_bump);
    downloads.removeListener(_bump);
    photos.removeListener(_bump);
    protection.removeListener(_applyProtection);
    peerLibraries.removeListener(_wireSources);
    player.removeListener(_syncWhenClosed);
    reader.removeListener(_syncWhenClosed);
    textReader.removeListener(_syncWhenClosed);
    // A controller handed in from outside is the caller's to dispose.
    if (widget.player == null) player.dispose();
    if (widget.reader == null) reader.dispose();
    if (widget.textReader == null) textReader.dispose();
    if (widget.fullscreen == null) fullscreen.dispose();
    if (widget.sync == null) sync.dispose();
    if (widget.host == null) host.dispose();
    if (widget.peerLibraries == null) peerLibraries.dispose();
    if (widget.downloads == null) downloads.dispose();
    if (widget.photos == null) photos.dispose();
    if (widget.protection == null) protection.dispose();
    navigation.dispose();
    super.dispose();
  }

  /// Re-reads the library when the shelf is locked or opened.
  ///
  /// The gate is applied where works are read, so a change to it means the
  /// lists have to be built again — otherwise unlocking would show nothing
  /// until something else happened to trigger a reload.
  void _applyProtection() {
    library.hides = protection.hides;
    library.refresh();
    _bump();
  }

  void _bump() => setState(() => _revision++);

  void setFilter(WorkFilter value) => setState(() => _filter = value);

  /// Shows one machine's shelf, or all of them again.
  void showSource(String? sourceId) {
    setState(() {
      _filter = _filter.copyWith(
        sourceId: sourceId,
        clearSource: sourceId == null,
      );
    });
    navigation.go(LibraryRoute(mediaTypeId: _filter.mediaTypeId));
  }

  /// Opens a saved view: the filter it stored, and the library showing it.
  void applySavedView(LibrarySavedView view) {
    setState(() => _filter = WorkFilterQuery.fromQuery(view.query));
    navigation.go(LibraryRoute(mediaTypeId: _filter.mediaTypeId));
  }

  /// Brings a paired machine's catalogue in and shows it.
  ///
  /// The index is written here, the files stay there. Afterwards nothing in
  /// the app is aware of the difference except the origin mark on a tile and
  /// the machine's name in the filter.
  Future<void> openPeerLibrary(PeerConnection peer) async {
    final opened = await peerLibraries.connect(peer);
    if (!opened) return;
    _wireSources();
    await _loadTrackPreference();
    navigation.reset(const DashboardRoute());
  }

  /// Connects to everything this device is paired with.
  ///
  /// The catalogues of the machines that answer come in; the ones that do not
  /// are simply not there yet, and their works stay in the index from last
  /// time.
  ///
  /// The reading positions come with them. A catalogue without them is a
  /// list of works that all claim never to have been opened — and the first
  /// thing anyone does after connecting is open the one they were in the
  /// middle of.
  Future<void> connectPairedMachines({bool withProgress = true}) async {
    if (settings.peers.isEmpty) return;
    await peerLibraries.connectAll();
    _wireSources();
    await _loadTrackPreference();
    if (withProgress) await sync.syncAll();
  }

  /// Lets go of every paired machine, keeping their catalogues.
  Future<void> closePeerLibraries() async {
    await peerLibraries.closeAll();
    _wireSources();
  }

  /// Sends a work's reading state on the moment it is put down.
  ///
  /// The manual button stays — it is what says whether the round worked. This
  /// is the case that button cannot cover: finishing an episode on the phone
  /// and wanting the Mac at the same place, without remembering to press
  /// anything.
  void _syncWhenClosed() {
    final playing = player.work?.id;
    final reading = reader.isOpen ? reader.work?.id : null;
    final texting = textReader.isOpen ? textReader.work?.id : null;
    final open = playing ?? reading ?? texting;
    if (open != null) {
      _lastOpenWorkId = open;
      return;
    }
    final closed = _lastOpenWorkId;
    if (closed == null) return;
    _lastOpenWorkId = null;
    unawaited(sync.pushWork(closed));
  }

  String? _lastOpenWorkId;

  /// Starts or resumes a work. One entry point, whatever the media type — a
  /// screen never decides between a player and a reader, and neither asks
  /// where the bytes come from.
  Future<void> play(WorkView work) async {
    final vault = library.library;
    if (vault == null) return;
    if (ReaderController.handles(work)) {
      // A comic in the audio player is silence with a progress bar: pages and
      // seconds are different units, so they get different controllers.
      await player.close();
      await reader.open(vault, work);
      if (reader.failure == null) library.refresh();
      return;
    }
    if (TextReaderController.handles(work)) {
      await player.close();
      await textReader.open(vault, work);
      if (textReader.failure == null) library.refresh();
      return;
    }
    if (PhotoController.handles(work)) {
      // A gallery is not a player: an album handed to libmpv would be a
      // slideshow nobody asked for.
      await photos.open(vault, work);
      return;
    }
    await player.open(vault, work);
    if (player.failure == null) library.refresh();
  }

  /// Leaves the gallery and returns to the library.
  void leavePhotos() {
    photos.close();
    leaveFullscreen();
  }

  /// Opens a media type. The filter follows the place, so switching areas
  /// never leaves a stale filter behind that would explain an empty screen.
  void openMediaType(String? mediaTypeId) {
    setState(() {
      _filter = _filter.copyWith(
        mediaTypeId: mediaTypeId,
        clearMediaType: mediaTypeId == null,
        text: '',
      );
    });
    navigation.go(LibraryRoute(mediaTypeId: mediaTypeId));
  }

  /// Shell settings are device-bound but portable: they live in the vault so
  /// a reinstall does not cost them, keyed by this device.
  static const shellProfileKind = 'shell';

  /// Where the player's language choice is kept. Its own section, because a
  /// device adopting another's settings should be able to take the reading
  /// setup without the language, or the other way round.
  static const videoProfileKind = 'video';

  /// Speed, skip distances and the sleep timer.
  static const playbackProfileKind = 'playback';

  Future<void> setThemeMode(ThemeMode mode) async {
    await settings.setThemeMode(mode);
    await _writeShellProfile();
  }

  /// Fullscreen means the whole screen: the window fills it and the chrome
  /// of whatever is open steps out of the way. Leaving brings it back — a
  /// player without controls and without a way to find them is a trap.
  Future<void> toggleFullscreen() async {
    final entering = !fullscreen.isActive;
    await fullscreen.toggle();
    if (entering) {
      if (player.isExpanded && player.showsChrome) player.toggleChrome();
      if (reader.isOpen && reader.showsChrome) reader.toggleChrome();
      if (textReader.isOpen && textReader.showsChrome) {
        textReader.toggleChrome();
      }
      return;
    }
    player.showChrome();
    reader.showChrome();
    textReader.showChrome();
  }

  /// Leaves fullscreen and puts the chrome back, whatever is open.
  Future<void> leaveFullscreen() async {
    await fullscreen.leave();
    player.showChrome();
    reader.showChrome();
    textReader.showChrome();
  }

  /// Shows or hides the list beside the player. It is a device setting like
  /// the theme, so it travels in the vault and survives a reinstall.
  Future<void> setPlayerPanelVisible(bool value) async {
    await settings.setPlayerPanelVisible(value);
    await _writeShellProfile();
  }

  Future<void> setDensity(FundusDensity density) async {
    await settings.setDensity(density);
    await _writeShellProfile();
  }

  /// Takes another device's settings over onto this one.
  ///
  /// Only the settings travel — the key stays this device's, so adopting can
  /// never make two installations claim the same identity.
  Future<void> adoptDeviceProfile(DeviceProfile other) async {
    final shell = other.settingsFor(shellProfileKind);
    final theme = shell['theme_mode'];
    if (theme is String) {
      await settings.setThemeMode(
        ThemeMode.values.firstWhere(
          (mode) => mode.name == theme,
          orElse: () => settings.themeMode,
        ),
      );
    }
    final panel = shell['player_panel_visible'];
    if (panel is bool) await settings.setPlayerPanelVisible(panel);
    final density = shell['density'];
    if (density is String) {
      await settings.setDensity(
        density == 'compact'
            ? FundusDensity.compact
            : FundusDensity.comfortable,
      );
    }
    final library = this.library.library;
    if (library == null || library.isReadOnly) return;
    final mine =
        await library.loadDeviceProfile(settings.deviceKey) ??
        DeviceProfile(
          key: settings.deviceKey,
          displayName: settings.deviceName,
          platform: defaultTargetPlatform.name,
        );
    var merged = mine;
    for (final entry in other.settings.entries) {
      final values = other.settingsFor(entry.key);
      if (values.isNotEmpty) merged = merged.withSettings(entry.key, values);
    }
    await library.saveDeviceProfile(merged);
  }

  /// Reads this device's stored settings back after a reinstall.
  Future<void> restoreShellProfile() async {
    final library = this.library.library;
    if (library == null) return;
    final profile = await library.loadDeviceProfile(settings.deviceKey);
    if (profile == null) {
      await _writeShellProfile();
      await _loadTrackPreference();
      return;
    }
    await adoptDeviceProfile(profile);
    await _loadTrackPreference();
  }

  /// Reads the remembered audio and subtitle languages out of the vault and
  /// hands them to the player.
  ///
  /// In the vault rather than in this installation's settings: reinstalling
  /// the app is exactly when losing them hurts, and the vault is what
  /// survives that.
  Future<void> _loadTrackPreference() async {
    final vault = library.library;
    if (vault == null) return;
    final profile = await vault.loadDeviceProfile(settings.deviceKey);
    player.preference = TrackPreference.fromJson(
      profile?.settingsFor(videoProfileKind) ?? const {},
    );
    player.onPreferenceChanged = _saveTrackPreference;
    player.habits = PlaybackPreference.fromJson(
      profile?.settingsFor(playbackProfileKind) ?? const {},
    );
    await player.setRate(player.habits.rate);
    player.onHabitsChanged = _savePlaybackPreference;
  }

  Future<void> _saveTrackPreference(TrackPreference value) =>
      _writeProfileSection(videoProfileKind, value.toJson());

  /// Changes how this device plays, and remembers it.
  Future<void> setPlaybackHabits(PlaybackPreference value) async {
    player.habits = value;
    await _savePlaybackPreference(value);
    _bump();
  }

  Future<void> _savePlaybackPreference(PlaybackPreference value) =>
      _writeProfileSection(playbackProfileKind, value.toJson());

  Future<void> _writeProfileSection(
    String kind,
    Map<String, Object?> values,
  ) async {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    final existing = await vault.loadDeviceProfile(settings.deviceKey);
    final profile =
        (existing ??
                DeviceProfile(
                  key: settings.deviceKey,
                  displayName: settings.deviceName,
                  platform: defaultTargetPlatform.name,
                ))
            .withSettings(kind, values);
    await vault.saveDeviceProfile(profile);
  }

  Future<void> _writeShellProfile() async {
    final library = this.library.library;
    if (library == null || library.isReadOnly) return;
    final existing = await library.loadDeviceProfile(settings.deviceKey);
    final profile =
        (existing ??
                DeviceProfile(
                  key: settings.deviceKey,
                  displayName: settings.deviceName,
                  platform: defaultTargetPlatform.name,
                ))
            .withSettings(shellProfileKind, {
              'theme_mode': settings.themeMode.name,
              'density': settings.density.name,
              'player_panel_visible': settings.playerPanelVisible,
            });
    await library.saveDeviceProfile(profile);
  }

  @override
  Widget build(BuildContext context) =>
      _FundusScopeMarker(state: this, revision: _revision, child: widget.child);
}

class _FundusScopeMarker extends InheritedWidget {
  const _FundusScopeMarker({
    required this.state,
    required this.revision,
    required super.child,
  });

  final FundusScopeState state;
  final int revision;

  @override
  bool updateShouldNotify(_FundusScopeMarker oldWidget) =>
      revision != oldWidget.revision;
}
