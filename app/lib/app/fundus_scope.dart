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
import '../features/work/progress_choice_sheet.dart';
import 'app_navigation.dart';
import 'fundus_log.dart';
import 'fullscreen.dart';
import 'pairing_scanner.dart';
import 'storage_access.dart';
import 'vault_access.dart';
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
    this.vaultAccess,
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

  /// How the permission to read the library folder is kept across restarts.
  /// Supplied by a test; the app builds one from the platform it runs on.
  final VaultAccess? vaultAccess;

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

class FundusScopeState extends State<FundusScope> with WidgetsBindingObserver {
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

  late final VaultAccess vaultAccess =
      widget.vaultAccess ??
      (SecurityScopedVaultAccess.platformNeedsIt
          ? SecurityScopedVaultAccess(
              read: () => settings.vaultBookmarks,
              write: settings.setVaultBookmarks,
            )
          : const OpenVaultAccess());
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
    library.busyElsewhere = () =>
        player.isPlaying ||
        player.isExpanded ||
        reader.isOpen ||
        textReader.isOpen ||
        photos.isOpen ||
        downloads.jobs.any(
          (job) =>
              job.state == DownloadState.running ||
              job.state == DownloadState.queued,
        );
    WidgetsBinding.instance.addObserver(this);
    _startCatchingUp();
  }

  /// Wie oft im Hintergrund gefragt wird, ob anderswo etwas weitergelaufen
  /// ist. Selten genug, um niemandem im Weg zu stehen, oft genug, dass das
  /// Handy in der Hand den Stand vom Mac schon kennt.
  static const catchUpEvery = Duration(seconds: 45);
  Timer? _catchUp;

  /// Holt die Stände der anderen Geräte, ohne zu scannen.
  ///
  /// „Fortsetzen" von Hand aktualisieren zu müssen war der Fehler dahinter:
  /// der Knopf las die ganze Bibliothek neu, und deshalb war er langsam und
  /// deshalb drückte man ihn ungern. Hier wird nur gefragt, was sich bewegt
  /// hat, und nur die betroffenen Zeilen werden aufgefrischt.
  Future<void> catchUpWithPeers() async {
    if (!mounted || settings.peers.isEmpty) return;
    final touched = await sync.pullRecent();
    if (!mounted || touched.isEmpty) return;
    for (final workId in touched) {
      library.refreshWork(workId);
    }
  }

  void _startCatchingUp() {
    _catchUp ??= Timer.periodic(
      catchUpEvery,
      (_) => unawaited(catchUpWithPeers()),
    );
  }

  /// Coming back to the app is the moment to look for what changed.
  ///
  /// Files arrive in a vault while Fundus is not in front of anyone — copied
  /// over from another machine, dropped in by a download. A check is cheap
  /// enough to make on every return, and it is the only way the library is
  /// right without being told.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      // Weglegen ist das Ende einer Sitzung, auch wenn nichts geschlossen
      // wurde. Auf dem Handy bleibt der Leser offen, wenn man zum Rechner
      // wechselt — und ein Stand, der erst beim Schließen loszieht, ist
      // genau dann nie losgezogen. Deshalb geht er hier.
      _pushOpenWork();
      return;
    }
    // Zurück in der App: erst die Stände der anderen Geräte — das ist
    // billig und beantwortet die Frage, die man beim Hinsehen hat —, und
    // erst danach die Frage nach neuen Dateien.
    unawaited(catchUpWithPeers());
    if (!settings.watchesLibrary) return;
    unawaited(library.checkForChanges());
  }

  /// Sends out where the work that is open right now stands.
  void _pushOpenWork() {
    final open =
        player.work?.id ??
        (reader.isOpen ? reader.work?.id : null) ??
        (textReader.isOpen ? textReader.work?.id : null) ??
        _lastOpenWorkId;
    if (open != null) _pushSoon(open);
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
      await FundusLog.instance.attach(_supportRoot!);
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
    WidgetsBinding.instance.removeObserver(this);
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
    _pushTimer?.cancel();
    _catchUp?.cancel();
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

  /// Tells the screens below that something they read has changed.
  ///
  /// Every state change in this scope has to go through here. The screens
  /// depend on an inherited widget whose `updateShouldNotify` compares this
  /// number and nothing else, so a `setState` that does not raise it rebuilds
  /// this widget and reaches none of them: „Ordnen nach" changed the filter
  /// and left the same view on the screen.
  void _bump([VoidCallback? change]) => setState(() {
    change?.call();
    _revision++;
  });

  void setFilter(WorkFilter value) => _bump(() => _filter = value);

  /// Shows one machine's shelf, or all of them again.
  void showSource(String? sourceId) {
    _bump(() {
      _filter = _filter.copyWith(
        sourceId: sourceId,
        clearSource: sourceId == null,
      );
    });
    navigation.go(LibraryRoute(mediaTypeId: _filter.mediaTypeId));
  }

  /// Opens a saved view: the filter it stored, and the library showing it.
  void applySavedView(LibrarySavedView view) {
    _bump(() {
      _activeViews = {view.id};
      _filter = WorkFilterQuery.fromQuery(view.query);
    });
    navigation.go(LibraryRoute(mediaTypeId: _filter.mediaTypeId));
  }

  /// The saved views this vault holds, for the chips over a shelf.
  List<LibrarySavedView> get savedViews => _savedViews;
  List<LibrarySavedView> _savedViews = const [];

  /// Which of them are switched on right now.
  Set<String> get activeViews => _activeViews;
  Set<String> _activeViews = const {};

  Future<void> reloadSavedViews() async {
    final vault = library.library;
    final views = await vault?.loadSavedViews() ?? const <LibrarySavedView>[];
    if (!mounted) return;
    _bump(() => _savedViews = views);
  }

  /// Switches one saved view on or off.
  ///
  /// Several at once read as „and also": what they ask for is merged, and the
  /// shelf shows what satisfies all of it. Switching the last one off leaves
  /// the shelf as it was — the media type stays, because that is where
  /// somebody is, not something they filtered.
  void toggleSavedView(LibrarySavedView view) {
    final active = {..._activeViews};
    if (!active.remove(view.id)) active.add(view.id);
    final mediaTypeId = _filter.mediaTypeId;
    var merged = const LibraryWorkQuery();
    for (final saved in _savedViews) {
      if (!active.contains(saved.id)) continue;
      merged = merged.merge(saved.query);
    }
    _bump(() {
      _activeViews = active;
      _filter = active.isEmpty
          ? WorkFilter(mediaTypeId: mediaTypeId, sort: _filter.sort)
          : WorkFilterQuery.fromQuery(
              merged,
            ).copyWith(mediaTypeId: mediaTypeId, sort: _filter.sort);
    });
  }

  /// Keeps what is on screen as a chip of its own.
  Future<void> saveCurrentView(String name) async {
    final vault = library.library;
    if (vault == null || vault.isReadOnly || name.trim().isEmpty) return;
    final views = await vault.saveView(name, _filter.toQuery());
    if (!mounted) return;
    _bump(() => _savedViews = views);
  }

  Future<void> deleteSavedView(String id) async {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    final views = await vault.deleteSavedView(id);
    if (!mounted) return;
    _bump(() {
      _savedViews = views;
      _activeViews = {..._activeViews}..remove(id);
    });
  }

  /// Die Listen dieses Tresors — Playlisten wie Leselisten.
  ///
  /// Eine Liste ist eine Ansicht auf Werke, keine Ablage: was in ihr steht,
  /// liegt weiter dort, wo es liegt, und dieselbe Folge darf in drei Listen
  /// stehen, ohne dreimal da zu sein.
  List<LibraryPlaylist> get playlists => _playlists;
  List<LibraryPlaylist> _playlists = const [];

  void reloadPlaylists() {
    final vault = library.library;
    final lists = vault?.listPlaylists() ?? const <LibraryPlaylist>[];
    if (!mounted) return;
    _bump(() => _playlists = lists);
  }

  /// Legt eine Liste an und gibt sie zurück, damit der Aufrufer gleich
  /// hineinlegen kann, was den Anlass gab.
  LibraryPlaylist? createPlaylist(String name, {String? mediaType}) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly || name.trim().isEmpty) return null;
    final list = vault.savePlaylist(name: name.trim(), mediaType: mediaType);
    reloadPlaylists();
    return list;
  }

  void addToPlaylist(String playlistId, PlaylistEntry entry) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    vault.addToPlaylist(playlistId: playlistId, entry: entry);
    reloadPlaylists();
  }

  void removeFromPlaylist(String playlistId, int index) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    vault.removeFromPlaylist(playlistId: playlistId, index: index);
    reloadPlaylists();
  }

  void reorderPlaylist(String playlistId, int from, int to) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    vault.reorderPlaylist(playlistId: playlistId, from: from, to: to);
    reloadPlaylists();
  }

  void renamePlaylist(String playlistId, String name) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly || name.trim().isEmpty) return;
    vault.renamePlaylist(playlistId: playlistId, name: name.trim());
    reloadPlaylists();
  }

  void deletePlaylist(String playlistId) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    vault.deletePlaylist(playlistId);
    reloadPlaylists();
  }

  /// Übersetzt die Zeilen einer Liste in das, was der Player abspielt.
  ///
  /// Eine Zeile ohne Datei ist ein ganzes Werk und bringt alle seine Dateien
  /// mit; eine Zeile mit Datei genau diese eine. Was nicht mehr da ist, fällt
  /// still heraus — eine Liste ist kein Bestandsnachweis.
  List<QueueEntry> queueFor(LibraryPlaylist list) {
    final vault = library.library;
    if (vault == null) return const [];
    final queue = <QueueEntry>[];
    for (final entry in list.entries) {
      final work = library.workById(entry.workId);
      if (work == null) continue;
      final tracks = vault.playbackTracks(entry.workId);
      if (entry.fileId == null) {
        for (final track in tracks) {
          queue.add(
            QueueEntry(
              work: work,
              track: track,
              // Ein ganzes Werk in einer Liste ist ein Hörbuch oder eine
              // Folge — und die macht dort weiter, wo sie stand.
              resume: track == tracks.first,
            ),
          );
        }
        continue;
      }
      for (final track in tracks) {
        if (track.fileId != entry.fileId) continue;
        queue.add(QueueEntry(work: work, track: track));
      }
    }
    return queue;
  }

  /// Spielt eine Liste ab [startIndex] — der Zeile, die jemand angetippt hat.
  Future<void> playPlaylist(LibraryPlaylist list, {int startIndex = 0}) async {
    final vault = library.library;
    if (vault == null) return;
    final queue = queueFor(list);
    if (queue.isEmpty) return;
    reader.close();
    textReader.close();
    await player.openQueue(
      vault,
      queue,
      name: list.name,
      startIndex: startIndex.clamp(0, queue.length - 1),
    );
    final work = player.work;
    if (player.failure == null && work != null) library.refreshWork(work.id);
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
      // Pausing is where somebody stops, not where they close. „Ich höre am
      // Mac auf und nehme das Handy" is a pause and a walk away, and if the
      // position only leaves on closing, the phone finds nothing.
      if (playing != null && !player.isPlaying) _pushSoon(playing);
      // Reading has no pause to listen for: a page is turned and then
      // nothing happens for a while. Every settled page is worth sending —
      // the debounce makes a burst of them one call.
      if (playing == null) _pushSoon(open);
      return;
    }
    final closed = _lastOpenWorkId;
    if (closed == null) return;
    _lastOpenWorkId = null;
    _pushSoon(closed);
  }

  String? _lastOpenWorkId;
  Timer? _pushTimer;
  String? _pushing;

  /// Sends one work's position out, at most once every few seconds.
  ///
  /// Pausing, seeking and stopping arrive as a burst of notifications; a call
  /// per notification would be a burst of network for one decision. The delay
  /// is short enough that picking up the other device finds it there.
  void _pushSoon(String workId) {
    if (_pushing == workId && (_pushTimer?.isActive ?? false)) return;
    _pushing = workId;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 2), () {
      _pushing = null;
      unawaited(sync.pushWork(workId));
    });
  }

  /// Starts or resumes a work. One entry point, whatever the media type — a
  /// screen never decides between a player and a reader, and neither asks
  /// where the bytes come from.
  /// [startAt] names one file of the work — the episode somebody tapped.
  /// Without it the work opens where it was left.
  /// [at] ist die Stelle, die jemand ausdrücklich gemeint hat — eine
  /// Kapitelmarke etwa. Ohne sie entscheidet der gespeicherte Stand.
  Future<void> play(WorkView work, {String? startAt, Duration? at}) async {
    final vault = library.library;
    if (vault == null) return;
    final span = FundusLog.instance.start('open', {
      'work': work.title,
      'kind': work.kind,
      'origin': work.origin.name,
    });
    // Eine bestimmte Folge zu wählen ist selbst die Antwort auf „wo
    // weitermachen" — dann ist die Frage keine.
    if (startAt == null) await settlePosition(vault, work);
    span.step('position');
    if (ReaderController.handles(work)) {
      // A comic in the audio player is silence with a progress bar: pages and
      // seconds are different units, so they get different controllers.
      await player.close();
      await reader.open(vault, work);
      if (reader.failure == null) library.refreshWork(work.id);
      await _fillTheScreen(work, opened: reader.failure == null);
      span.done({'via': 'reader'});
      return;
    }
    if (TextReaderController.handles(work)) {
      await player.close();
      await textReader.open(vault, work);
      if (textReader.failure == null) library.refreshWork(work.id);
      await _fillTheScreen(work, opened: textReader.failure == null);
      span.done({'via': 'text'});
      return;
    }
    if (PhotoController.handles(work)) {
      // A gallery is not a player: an album handed to libmpv would be a
      // slideshow nobody asked for.
      await photos.open(vault, work);
      span.done({'via': 'photos'});
      return;
    }
    await player.open(vault, work, startAt: startAt, at: at);
    if (player.failure == null) library.refreshWork(work.id);
    await _fillTheScreen(work, opened: player.failure == null);
    span.done({'via': 'player'});
  }

  /// Pressing play means watching, so the screen is given over to it.
  ///
  /// Anything with a picture — a film, a series, a comic, a page of text —
  /// starts full screen with the chrome out of the way, and on a phone a film
  /// turns the device: held upright it is a stripe between two black bars.
  /// Audio is left alone; there is nothing to fill a screen with, and the
  /// controls are the point.
  Future<void> _fillTheScreen(WorkView work, {required bool opened}) async {
    if (!opened) return;
    final video = work.mediaType?.showsVideo ?? false;
    final reading = reader.isOpen || textReader.isOpen;
    if (!video && !reading) return;
    await fullscreen.enter(landscape: video);
    if (player.isExpanded && player.showsChrome) player.toggleChrome();
    if (reader.isOpen && reader.showsChrome) reader.toggleChrome();
    if (textReader.isOpen && textReader.showsChrome) textReader.toggleChrome();
  }

  /// Asks where to carry on, when two devices disagree.
  ///
  /// The sync has to choose — a position is not mergeable, and a dialog in
  /// the middle of a run would be about works nobody is thinking about — but
  /// the side it did not take is kept. Here is where that becomes a question,
  /// because this is the moment somebody is thinking about this work.
  ///
  /// Answering it either way settles it. An unanswered dialog counts as
  /// staying here: a question that comes back every time is not a question.
  Future<void> settlePosition(FundusLibrary vault, WorkView work) async {
    if (vault.isReadOnly) return;
    // First ask the other machines about this one work, right now.
    //
    // Waiting for the periodic round is what made a position take until the
    // next start to show up: it runs over the whole catalogue, at its own
    // rhythm, about works nobody is thinking about. Stopping on the Mac and
    // picking up the phone is one work and one moment, so it is one call —
    // with a short deadline, because this sits between pressing play and
    // anything happening.
    await _askElsewhere(vault, work);
    final other = vault.progressChoice(work.id);
    if (other == null) return;
    final mine = vault.loadProgress(work.id);
    if (mine != null && _samePlace(mine.position, other.position)) {
      vault.clearProgressChoice(work.id);
      return;
    }
    // Somebody who has said „immer die weiteste Stelle" has answered this
    // question once and for all; asking again is not asking, it is nagging.
    if (settings.alwaysFurthestPosition) {
      final order = [
        for (final track in vault.playbackTracks(work.id)) track.fileId,
      ];
      final furthest =
          mine == null ||
          comparePositions(other.position, mine.position, fileOrder: order) > 0;
      if (furthest) {
        vault.takeProgressChoice(work.id, deviceId: settings.deviceKey);
      } else {
        vault.clearProgressChoice(work.id);
      }
      library.refreshWork(work.id);
      return;
    }
    if (!mounted) return;
    final answer = await showProgressChoiceSheet(
      context,
      work: work,
      other: other,
      mine: mine,
      thisDevice: settings.deviceName,
      tracks: vault.playbackTracks(work.id),
    );
    // Dismissed without answering: stay here, and stop asking about this one.
    // A question that comes back every time is not a question.
    if (answer?.always ?? false) {
      await settings.setAlwaysFurthestPosition(true);
    }
    if (answer?.takeOther ?? false) {
      vault.takeProgressChoice(work.id, deviceId: settings.deviceKey);
    } else {
      vault.clearProgressChoice(work.id);
      // Staying here is a decision the other machine has to hear about, or
      // the next device picked up asks the same question again.
      unawaited(sync.pushWork(work.id));
    }
    library.refreshWork(work.id);
  }

  /// Fetches this work's position from the paired machines and, if one of
  /// them stands somewhere else, writes it down as the open question.
  ///
  /// It goes through the same place a sync's leftovers go, so there is one
  /// path to the sheet and one path to „immer die weiteste Stelle" rather
  /// than two that can disagree.
  Future<void> _askElsewhere(FundusLibrary vault, WorkView work) async {
    if (sync.peers.isEmpty) return;
    final span = FundusLog.instance.start('position.ask', {'work': work.title});
    try {
      final elsewhere = await sync.furthestElsewhere(work.id);
      if (elsewhere == null) {
        span.done({'answer': 'none'});
        return;
      }
      final mine = vault.loadProgress(work.id);
      final theirs = elsewhere.progress;
      if (mine != null && _samePlace(mine.position, theirs.position)) {
        span.done({'answer': 'same'});
        return;
      }
      vault.recordProgressChoice(
        LibraryProgressChoice(
          workId: work.id,
          position: theirs.position,
          fileId: theirs.fileId,
          finished: theirs.finished,
          deviceId: theirs.deviceId.isEmpty
              ? elsewhere.peerName
              : theirs.deviceId,
          deviceName: elsewhere.peerName,
          updatedAt: theirs.updatedAt,
          recordedAt: DateTime.now().toUtc(),
        ),
      );
      span.done({'answer': 'differs'});
    } on Object catch (error) {
      // A machine that will not answer must not hold up a film.
      span.failed(error);
    }
  }

  /// Two positions that are the same place are not a question.
  static bool _samePlace(MediaPosition left, MediaPosition right) =>
      left.kind == right.kind &&
      left.fileId == right.fileId &&
      left.elementId == right.elementId &&
      ((left.numericValue ?? 0) - (right.numericValue ?? 0)).abs() < 1;

  /// Leaves the gallery and returns to the library.
  void leavePhotos() {
    photos.close();
    leaveFullscreen();
  }

  /// Opens a media type. The filter follows the place, so switching areas
  /// never leaves a stale filter behind that would explain an empty screen.
  void openMediaType(String? mediaTypeId) {
    _bump(() {
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

  /// Marks a work as a favourite, or takes the mark back.
  ///
  /// It lives in the vault rather than on this device: „das mag ich" is a
  /// statement about the work, and it should be true on the phone as well.
  void toggleFavourite(WorkView work) {
    final vault = library.library;
    if (vault == null || vault.isReadOnly) return;
    vault.setFavourite(workId: work.id, favourite: !work.summary.favourite);
    library.refreshWork(work.id);
    unawaited(sync.pushWork(work.id));
  }

  /// Changes the standing language rules, and remembers them.
  Future<void> setTrackRules(TrackPreference value) async {
    player.preference = value;
    await _saveTrackPreference(value);
    _bump();
  }

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
