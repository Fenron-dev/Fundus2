import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../database/fundus_database.dart';
import '../import/abs_importer.dart';
import '../import/abs_metadata.dart';
import '../import/document_importer.dart';
import '../import/embedded_cover.dart';
import '../import/media_areas.dart';
import '../model/device_profile.dart';
import '../model/fundus_id.dart';
import '../model/library_configuration.dart';
import '../model/library_manifest.dart';
import '../model/library_playlist.dart';
import '../model/library_saved_view.dart';
import '../model/library_source.dart';
import '../model/media_position.dart';
import '../model/playback_session.dart';
import '../playback/library_playback.dart';
import 'remote_catalogue.dart';
import '../publication/epub_package.dart';
import '../publication/publication_engine.dart';
import '../scan/background_scan.dart';
import '../scan/library_scanner.dart';
import '../search/library_work_query.dart';
import 'work_annotations.dart';

enum LibraryIndexPhase { scanning, importing, completed, cancelled }

final class LibraryIndexEvent {
  const LibraryIndexEvent({
    required this.phase,
    required this.fileCount,
    this.workCount = 0,
    this.changedWorkCount = 0,
    this.changedFileCount = 0,
    this.currentPath,
    this.rootCounts = const {},
    this.extensionCounts = const {},
    this.unreadableFolders = const [],
  });

  final LibraryIndexPhase phase;
  final int fileCount;
  final int workCount;

  /// How many works this pass actually rewrote. In a full pass that is all of
  /// them; in a check it is the ones something happened to.
  final int changedWorkCount;

  /// New, altered and vanished files — what the check found to do.
  final int changedFileCount;

  final String? currentPath;
  final Map<String, int> rootCounts;
  final Map<String, int> extensionCounts;

  /// Folders the walk could not open. Nothing below them was judged.
  final List<String> unreadableFolders;
}

final class _PortableWorkIdentity {
  const _PortableWorkIdentity({
    this.workId,
    required this.writable,
    this.identity,
  });

  final String? workId;
  final bool writable;
  final AbsBookIdentity? identity;
}

final class FundusLibrary {
  FundusLibrary._({
    required this.root,
    required this.manifest,
    required LibraryConfiguration configuration,
    required this.openMode,
    required FundusDatabase database,
  }) : _configuration = configuration,
       _database = database;

  /// Sidecar writes run one after another.
  ///
  /// Two settings saved at the same moment used to share one `.part` file:
  /// the first rename moved it away and the second failed with a missing
  /// file, which on a slow machine cost the setting that was just made.
  Future<void> _sidecarWrites = Future.value();
  int _sidecarCounter = 0;

  static const metadataDirectoryName = '.library';
  static const manifestFileName = 'version.json';
  static const databaseFileName = 'index.db';
  static const configurationFileName = 'config.yaml';

  final Directory root;
  final LibraryManifest manifest;
  LibraryConfiguration _configuration;

  /// Which folder names count as which media area. Editable per library.
  LibraryConfiguration get configuration => _configuration;
  final LibraryOpenMode openMode;
  final FundusDatabase _database;

  bool get isReadOnly => openMode != LibraryOpenMode.readWrite;

  static Future<FundusLibrary> create(
    Directory root, {
    String createdBy = 'Fundus',
  }) async {
    await root.create(recursive: true);
    final manifestFile = _manifestFile(root);
    if (await manifestFile.exists()) return open(root);
    final manifest = LibraryManifest(
      libraryId: FundusId.generate(),
      formatVersion: LibraryManifest.currentFormatVersion,
      minReaderVersion: LibraryManifest.currentReaderVersion,
      createdBy: createdBy,
    );
    await manifest.write(manifestFile);
    final configuration = LibraryConfiguration();
    await configuration.write(_configurationFile(root));
    final library = FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      configuration: configuration,
      openMode: LibraryOpenMode.readWrite,
      database: FundusDatabase.openFile(_databaseFile(root)),
    );
    library._registerAsSource();
    return library;
  }

  static Future<FundusLibrary> open(Directory root) async {
    final manifestFile = _manifestFile(root);
    if (!await manifestFile.exists()) {
      throw FileSystemException(
        'In diesem Ordner wurde keine Fundus-Bibliothek gefunden.',
        root.path,
      );
    }
    final manifest = await LibraryManifest.read(manifestFile);
    final configuration = await LibraryConfiguration.readOrDefault(
      _configurationFile(root),
    );
    final compatibility = manifest.compatibility();
    if (compatibility.mode == LibraryOpenMode.incompatible) {
      throw StateError(compatibility.message);
    }
    final library = FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      configuration: configuration,
      openMode: compatibility.mode,
      database: FundusDatabase.openFile(
        _databaseFile(root),
        readOnly: compatibility.mode == LibraryOpenMode.readOnly,
      ),
    );
    if (compatibility.mode == LibraryOpenMode.readWrite) {
      library._registerAsSource();
    }
    return library;
  }

  /// Records the opened vault as a source of its own.
  ///
  /// The path is stored because it is how this device finds the vault again;
  /// it is never handed out and never synchronised. The `library_id` from the
  /// manifest is what actually identifies the vault when the drive letter or
  /// mount point changes.
  void _registerAsSource() {
    final existing = _database.loadSource(FundusDatabase.localSourceId);
    _database.upsertSource(
      LibrarySource(
        id: FundusDatabase.localSourceId,
        kind: LibrarySourceKind.vault,
        displayName: existing?.displayName.isNotEmpty ?? false
            ? existing!.displayName
            : p.basename(root.path),
        libraryId: manifest.libraryId,
        vaultPath: root.path,
        syncCursor: existing?.syncCursor ?? 0,
        status: LibrarySourceStatus.available,
        lastSeenAt: DateTime.now(),
      ),
    );
  }

  /// Records another Fundus as a source this vault carries works from.
  ///
  /// A vault is normally its own source and nothing else. A device without
  /// media of its own — a phone — is the case this exists for: the vault is
  /// then an index and a place for reading state, and the works in it live on
  /// the machine named here.
  LibrarySource registerPeerSource({
    required String sourceId,
    required String displayName,
    required String libraryId,
    required String baseUrl,
    String? certificatePin,
  }) {
    _ensureWritable();
    final source = LibrarySource(
      id: sourceId,
      kind: LibrarySourceKind.peer,
      displayName: displayName,
      libraryId: libraryId,
      baseUrl: baseUrl,
      certificatePin: certificatePin,
      status: LibrarySourceStatus.available,
      lastSeenAt: DateTime.now(),
    );
    _database.upsertSource(source);
    return source;
  }

  /// Writes what the peer has into this vault's index.
  /// Writes what the peer has into this vault's index.
  ///
  /// [keepIds] names every work the other side still holds, for the case
  /// where [works] is only what changed. Without it, a delta would look like
  /// a catalogue that had lost almost everything.
  RemoteMirrorReport mirrorRemoteCatalogue({
    required String sourceId,
    required List<RemoteWorkRecord> works,
    Set<String>? keepIds,
  }) {
    _ensureWritable();
    return _database.mirrorRemoteCatalogue(
      sourceId: sourceId,
      works: works,
      keepIds: keepIds,
    );
  }

  /// Records a downloaded copy of a remote file.
  void setOfflineCopy({required String fileId, required String path}) {
    _ensureWritable();
    _database.setOfflineCopy(fileId: fileId, path: path);
  }

  /// Gives a file back to the network — the copy is gone or unwanted.
  void clearOfflineCopy(String fileId) {
    _ensureWritable();
    _database.clearOfflineCopy(fileId);
  }

  /// Every content file of a work, with where its bytes are.
  List<
    ({String fileId, String filename, String? offlinePath, String availability})
  >
  contentFiles(String workId) => _database.contentFiles(workId);

  /// What a mirror last saw of a source, as work id → state marker.
  ///
  /// Kept beside the index it belongs to rather than with the app: it
  /// describes the *vault's* copy of a peer catalogue, so it is only true for
  /// this folder, and a folder moved to another device brings it along.
  Future<Map<String, String>> loadMirrorState(String sourceId) async {
    final file = _mirrorStateFile(sourceId);
    if (!await file.exists()) return const {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } on FormatException {
      // A damaged marker file costs one full catalogue fetch, nothing more.
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  Future<void> saveMirrorState(
    String sourceId,
    Map<String, String> state,
  ) async {
    _ensureWritable();
    await _writeSidecar(_mirrorStateFile(sourceId), jsonEncode(state));
  }

  File _mirrorStateFile(String sourceId) {
    final safe = sourceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(
      p.join(root.path, metadataDirectoryName, 'mirrors', '$safe.json'),
    );
  }

  /// The last common state per work, for a peer, and the journal beside it.
  ///
  /// In the vault rather than with the app: it describes agreements this
  /// *library* reached with another one, so a folder carried to another
  /// device brings them along and does not start over.
  Future<Map<String, String>> loadSyncBaseline(String peerId) =>
      _readJsonMap(_syncFile(peerId, 'baseline'));

  Future<void> saveSyncBaseline(String peerId, Map<String, String> marks) {
    _ensureWritable();
    return _writeSidecar(_syncFile(peerId, 'baseline'), jsonEncode(marks));
  }

  /// What the last few syncs decided, newest first.
  Future<List<Map<String, Object?>>> loadSyncJournal(String peerId) async {
    final file = _syncFile(peerId, 'journal');
    if (!await file.exists()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) Map<String, Object?>.from(entry.cast()),
      ];
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    }
  }

  /// Keeps the newest [limit] entries and forgets the rest — a journal that
  /// grows without bound is a file nobody ever reads the end of.
  Future<void> saveSyncJournal(
    String peerId,
    List<Map<String, Object?>> entries, {
    int limit = 200,
  }) {
    _ensureWritable();
    return _writeSidecar(
      _syncFile(peerId, 'journal'),
      jsonEncode(entries.take(limit).toList()),
    );
  }

  Future<Map<String, String>> _readJsonMap(File file) async {
    if (!await file.exists()) return const {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  File _syncFile(String peerId, String what) {
    final safe = peerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(
      p.join(root.path, metadataDirectoryName, 'sync', '$safe.$what.json'),
    );
  }

  /// Forgets a source and everything this vault only knew through it.
  ///
  /// Only for a mirrored source: the works were never here as files, so
  /// removing them removes an index and nothing else. What the person did —
  /// positions, marks — goes with them, which is the point: they were about
  /// works this device can no longer reach or name.
  void dropSource(String sourceId) {
    _ensureWritable();
    _database.dropSource(sourceId);
  }

  /// Whether a source is answering right now.
  ///
  /// Works of an unreachable source stay in the index and stay visible; only
  /// their origin changes, so a library does not empty itself because the
  /// other machine is asleep.
  void setSourceReachable(String sourceId, {required bool reachable}) {
    _ensureWritable();
    _database.setSourceReachable(sourceId, reachable: reachable);
  }

  /// Renames the vault as this device shows it.
  ///
  /// The folder name is the default and usually right. It is not right for a
  /// vault that only holds another machine's catalogue: there the library is
  /// called what that machine is called, not what its folder happens to be.
  void setVaultDisplayName(String name) {
    _ensureWritable();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = _database.loadSource(FundusDatabase.localSourceId);
    if (existing == null) return;
    _database.upsertSource(
      LibrarySource(
        id: existing.id,
        kind: existing.kind,
        displayName: trimmed,
        libraryId: existing.libraryId,
        vaultPath: existing.vaultPath,
        syncCursor: existing.syncCursor,
        status: existing.status,
        lastSeenAt: existing.lastSeenAt,
      ),
    );
  }

  List<LibrarySource> listSources() => _database.listSources();

  /// Every folder name the library currently recognises, lower-cased.
  Set<String> get configuredRootNames => {
    for (final roots in configuration.mediaRoots.values)
      for (final root in roots)
        if (root.isNotEmpty) root.split('/').first.toLowerCase(),
  };

  /// Assigns a top-level folder to a media area and stores it with the
  /// library, so the choice travels with the vault rather than with the app.
  Future<void> assignMediaRoot({
    required String folder,
    required String kind,
  }) async {
    _ensureWritable();
    final name = folder.trim();
    if (name.isEmpty) {
      throw ArgumentError('Der Ordnername darf nicht leer sein.');
    }
    final roots = <String, Iterable<String>>{
      for (final entry in configuration.mediaRoots.entries)
        entry.key: entry.value.where(
          (value) => value.toLowerCase() != name.toLowerCase(),
        ),
    };
    roots[kind] = [...?roots[kind], name];
    await saveConfiguration(LibraryConfiguration(mediaRoots: roots));
  }

  Future<void> saveConfiguration(LibraryConfiguration next) async {
    _ensureWritable();
    await next.write(_configurationFile(root));
    _configuration = next;
  }

  /// A short stamp of the folder assignment the index was last built from.
  ///
  /// Which area a work belongs to is decided from its folder name, so
  /// renaming an area or assigning a new folder changes the answer for files
  /// nobody touched. A check compares file times and would find nothing to
  /// do; the pass has to be a full one instead, and this is how it knows.
  String get _configurationFingerprint {
    final entries = [
      for (final entry in configuration.mediaRoots.entries)
        '${entry.key}=${([...entry.value]..sort()).join(',')}',
    ]..sort();
    return entries.join(';');
  }

  File get _indexStateFile =>
      File(p.join(root.path, metadataDirectoryName, 'index-state.json'));

  Future<bool> _folderAssignmentChanged() async {
    try {
      final file = _indexStateFile;
      if (!await file.exists()) return true;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is! Map ||
          decoded['media_roots'] != _configurationFingerprint;
    } on Object {
      return true;
    }
  }

  Future<void> _rememberFolderAssignment() async {
    try {
      final file = _indexStateFile;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'media_roots': _configurationFingerprint}),
        flush: true,
      );
    } on FileSystemException {
      // Losing the marker only costs one full pass more than needed.
    }
  }

  /// The device profiles stored with this vault.
  ///
  /// See [DeviceProfile] for why they live here rather than in app storage:
  /// an app reinstall must not cost the reader settings again.
  Future<List<DeviceProfile>> listDeviceProfiles() async {
    final directory = _deviceProfileDirectory;
    if (!await directory.exists()) return const [];
    final profiles = <DeviceProfile>[];
    await for (final entry in directory.list()) {
      if (entry is! File || !entry.path.endsWith('.yaml')) continue;
      final profile = await _readDeviceProfile(entry);
      if (profile != null) profiles.add(profile);
    }
    profiles.sort((a, b) => a.displayName.compareTo(b.displayName));
    return profiles;
  }

  Future<DeviceProfile?> loadDeviceProfile(String key) =>
      _readDeviceProfile(_deviceProfileFile(key));

  Future<void> saveDeviceProfile(DeviceProfile profile) async {
    _ensureWritable();
    await _writeSidecar(
      _deviceProfileFile(profile.key),
      '${const JsonEncoder.withIndent('  ').convert(profile.toJson())}\n',
    );
  }

  Future<void> deleteDeviceProfile(String key) async {
    _ensureWritable();
    final file = _deviceProfileFile(key);
    if (await file.exists()) await file.delete();
  }

  /// The reader profile for a work, falling back to the vault's default.
  ///
  /// Layout, reading direction and page scale belong to the vault, not to the
  /// app: reinstalling once cost every manga its reading direction, and that
  /// must not happen again. A work without its own profile inherits the
  /// default, so a new series starts the way the last one was read.
  Future<PublicationReaderProfile> loadReaderProfile({String? workId}) async {
    if (workId != null) {
      final own = await _readReaderProfile(_readerProfileFile(workId));
      if (own != null) return own;
    }
    return await _readReaderProfile(_readerProfileFile(_defaultReaderKey)) ??
        const PublicationReaderProfile();
  }

  /// Writes the profile for one work and, at the same time, as the default —
  /// the next series then opens the way this one is being read.
  Future<void> saveReaderProfile(
    PublicationReaderProfile profile, {
    String? workId,
  }) async {
    _ensureWritable();
    final contents =
        '${const JsonEncoder.withIndent('  ').convert(profile.toJson())}\n';
    for (final key in {?workId, _defaultReaderKey}) {
      await _writeSidecar(_readerProfileFile(key), contents);
    }
  }

  /// The text profile for a work, falling back to the vault's default.
  ///
  /// Same reasoning as the comic profile: type size is a setting nobody wants
  /// to make twice, least of all after a reinstall.
  Future<ReflowReaderProfile> loadTextProfile({String? workId}) async {
    if (workId != null) {
      final own = await _readTextProfile(_textProfileFile(workId));
      if (own != null) return own;
    }
    return await _readTextProfile(_textProfileFile(_defaultReaderKey)) ??
        const ReflowReaderProfile();
  }

  Future<void> saveTextProfile(
    ReflowReaderProfile profile, {
    String? workId,
  }) async {
    _ensureWritable();
    final contents =
        '${const JsonEncoder.withIndent('  ').convert(profile.toJson())}\n';
    for (final key in {?workId, _defaultReaderKey}) {
      await _writeSidecar(_textProfileFile(key), contents);
    }
  }

  File _textProfileFile(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(p.join(_readerProfileDirectory.path, 'text', '$safe.json'));
  }

  Future<ReflowReaderProfile?> _readTextProfile(File file) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      return ReflowReaderProfile.fromJson(Map<String, Object?>.from(value));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static const _defaultReaderKey = 'default';

  Directory get _readerProfileDirectory =>
      Directory(p.join(root.path, '_fundus', 'readers'));

  File _readerProfileFile(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(p.join(_readerProfileDirectory.path, '$safe.json'));
  }

  Future<PublicationReaderProfile?> _readReaderProfile(File file) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      return PublicationReaderProfile.fromJson(
        Map<String, Object?>.from(value),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      // A profile written by a newer version is not worth refusing to read a
      // book over; the defaults still work.
      return null;
    }
  }

  Directory get _deviceProfileDirectory =>
      Directory(p.join(root.path, '_fundus', 'devices'));

  File _deviceProfileFile(String key) {
    // The key becomes a file name, so anything that could climb out of the
    // directory is stripped rather than trusted.
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File(p.join(_deviceProfileDirectory.path, '$safe.yaml'));
  }

  /// Waits until everything asked of the sidecars is on disk.
  ///
  /// The writes are queued, so a setting made a moment ago may still be in
  /// flight. Anything that has to see it — closing the vault, a test reading
  /// the file back — waits here rather than guessing at a delay.
  Future<void> flushSidecarWrites() => _sidecarWrites;

  /// Writes [contents] to [file] so that a reader never sees half of it, and
  /// so that a second writer cannot pull the ground away.
  Future<void> _writeSidecar(File file, String contents) {
    final operation = _sidecarWrites.then((_) async {
      await file.parent.create(recursive: true);
      // A name of its own per write: a shared one is what let two writers
      // collide in the first place.
      final partial = File('${file.path}.${_sidecarCounter++}.part');
      try {
        await partial.writeAsString(contents, flush: true);
        if (await file.exists()) await file.delete();
        await partial.rename(file.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    });
    // The chain must survive a failed write, or one error would block every
    // later setting.
    _sidecarWrites = operation.catchError((Object _) {});
    return operation;
  }

  Future<DeviceProfile?> _readDeviceProfile(File file) async {
    if (!await file.exists()) return null;
    try {
      return DeviceProfile.fromJson(loadYaml(await file.readAsString()));
    } on FileSystemException {
      return null;
    } on YamlException {
      return null;
    }
  }

  List<LibraryWorkSummary> listWorks({bool includeMissing = false}) => _database
      .listWorks(includeMissing: includeMissing)
      .map(_withAbsoluteCoverPath)
      .toList(growable: false);

  List<LibraryWorkSummary> searchWorks([
    LibraryWorkQuery query = const LibraryWorkQuery(),
  ]) => LibraryWorkSearch.apply(listWorks(), query);

  Future<List<LibrarySavedView>> loadSavedViews() async {
    final file = File(
      p.join(root.path, metadataDirectoryName, 'saved_views.json'),
    );
    if (!await file.exists()) return const [];
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! List) return const [];
      final views = value
          .map(LibrarySavedView.fromJson)
          .whereType<LibrarySavedView>()
          .toList();
      views.sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
      return views;
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Future<List<LibrarySavedView>> saveView(
    String name,
    LibraryWorkQuery query,
  ) async {
    _ensureWritable();
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Der Name darf nicht leer sein.');
    }
    final views = await loadSavedViews();
    final existing = views
        .where((view) => view.name.toLowerCase() == normalized.toLowerCase())
        .firstOrNull;
    final saved = LibrarySavedView(
      id: existing?.id ?? FundusId.generate(),
      name: normalized,
      query: query,
      updatedAt: DateTime.now().toUtc(),
    );
    final updated = [...views.where((view) => view.id != saved.id), saved]
      ..sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    await _writeSavedViews(updated);
    return updated;
  }

  Future<List<LibrarySavedView>> deleteSavedView(String id) async {
    _ensureWritable();
    final updated = (await loadSavedViews())
        .where((view) => view.id != id)
        .toList(growable: false);
    await _writeSavedViews(updated);
    return updated;
  }

  Future<void> _writeSavedViews(List<LibrarySavedView> views) async {
    final file = File(
      p.join(root.path, metadataDirectoryName, 'saved_views.json'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(views.map((view) => view.toJson()).toList())}\n',
      flush: true,
    );
  }

  void deleteMissingWork(String workId) {
    _ensureWritable();
    _database.deleteMissingWork(workId);
  }

  List<LibraryPlaybackTrack> playbackTracks(String workId) {
    return _database
        .playbackTracks(workId)
        .map((track) {
          // A downloaded copy is a file like any other, and from here on it
          // is *the* file: the players and readers open it and never ask the
          // network again.
          final copy = track.offlinePath;
          final remote =
              track.sourceId != FundusDatabase.localSourceId && copy == null;
          // A remote file has no path on this device, and joining one onto
          // the vault root would invent a file that is not there. The caller
          // asks the source where the bytes are; here it only says that they
          // are elsewhere.
          final absolutePath =
              copy ??
              (remote ? '' : p.normalize(p.join(root.path, track.path)));
          if (!remote && copy == null && !p.isWithin(root.path, absolutePath)) {
            throw StateError(
              'Unsicherer Medienpfad im Bibliotheksindex: ${track.path}',
            );
          }
          return LibraryPlaybackTrack(
            fileId: track.fileId,
            relativePath: track.path,
            absolutePath: absolutePath,
            sourceId: remote ? track.sourceId : FundusDatabase.localSourceId,
            title: track.title,
            index: track.position,
            duration: track.durationMs == null
                ? null
                : Duration(milliseconds: track.durationMs!),
            audioMetadata: track.audioMetadata,
            episode: track.episode,
          );
        })
        .toList(growable: false);
  }

  /// Resolves a file through the indexed relation instead of walking all
  /// works. The server uses this for every stream request.
  String? workIdForFile(String fileId) => _database.workIdForFile(fileId);

  /// Whether this work is the kind whose one file names its own chapters.
  static const _chapteredKinds = {'audiobook', 'podcast', 'podcast_episode'};

  bool _carriesChapters(String workId) {
    final kind = _database.workKind(workId);
    return kind != null && _chapteredKinds.contains(kind);
  }

  Future<List<LibraryPlaybackChapter>> playbackChapters(String workId) async {
    final tracks = playbackTracks(workId);
    if (tracks.isEmpty) return const [];
    if (tracks.length > 1) {
      return [
        for (var index = 0; index < tracks.length; index++)
          LibraryPlaybackChapter(
            title: p.basenameWithoutExtension(tracks[index].title),
            fileId: tracks[index].fileId,
            trackIndex: index,
            position: Duration.zero,
            duration: tracks[index].duration,
          ),
      ];
    }

    final track = tracks.single;
    // Only where chapters are a thing the file actually carries.
    //
    // Looking for them means walking the container's atom tree, header by
    // header, seeking as it goes — over a network share that is hundreds of
    // round trips before the first frame. It is how an audiobook in one file
    // names its chapters, and it is not how a film does anything: a film has
    // one entry either way, so the walk buys nothing and costs the wait
    // before playback starts.
    if (!_carriesChapters(workId)) {
      return [
        LibraryPlaybackChapter(
          title: p.basenameWithoutExtension(track.title),
          fileId: track.fileId,
          trackIndex: 0,
          position: Duration.zero,
          duration: track.duration,
        ),
      ];
    }
    final embedded = await const EmbeddedCoverExtractor().extractChapters(
      File(track.absolutePath),
    );
    if (embedded.isEmpty) {
      return [
        LibraryPlaybackChapter(
          title: p.basenameWithoutExtension(track.title),
          fileId: track.fileId,
          trackIndex: 0,
          position: Duration.zero,
          duration: track.duration,
        ),
      ];
    }
    return [
      for (var index = 0; index < embedded.length; index++)
        LibraryPlaybackChapter(
          title: embedded[index].title,
          fileId: track.fileId,
          trackIndex: 0,
          position: embedded[index].position,
          duration: index + 1 < embedded.length
              ? embedded[index + 1].position - embedded[index].position
              : track.duration == null
              ? null
              : track.duration! - embedded[index].position,
        ),
    ];
  }

  /// The chapters inside one file of a work.
  ///
  /// A podcast is a folder of episodes, so the work's own chapter list is a
  /// list of episodes and says nothing about what is inside one of them. This
  /// looks into the file that is playing — which is where a podcast keeps its
  /// chapters, and its chapter pictures.
  Future<List<LibraryPlaybackChapter>> trackChapters(
    String workId,
    String fileId,
  ) async {
    final track = playbackTracks(
      workId,
    ).where((candidate) => candidate.fileId == fileId).firstOrNull;
    if (track == null) return const [];
    final embedded = await const EmbeddedCoverExtractor().extractChapters(
      File(track.absolutePath),
    );
    if (embedded.length < 2) return const [];
    final index = playbackTracks(
      workId,
    ).indexWhere((candidate) => candidate.fileId == fileId);
    return [
      for (var position = 0; position < embedded.length; position++)
        LibraryPlaybackChapter(
          title: embedded[position].title,
          fileId: fileId,
          trackIndex: index < 0 ? 0 : index,
          position: embedded[position].position,
          duration: position + 1 < embedded.length
              ? embedded[position + 1].position - embedded[position].position
              : track.duration == null
              ? null
              : track.duration! - embedded[position].position,
          imagePath: await _keepChapterImage(
            fileId: fileId,
            index: position,
            image: embedded[position].image,
          ),
        ),
    ];
  }

  /// Unpacks a chapter picture once and hands back where it lies.
  ///
  /// Inside the file it is unreachable for anything that draws pictures, and
  /// carrying a few megabytes of image bytes through the player for every
  /// chapter is not a plan. Written next to the covers, named after the file
  /// it came out of, and written only once.
  Future<String?> _keepChapterImage({
    required String fileId,
    required int index,
    required EmbeddedCover? image,
  }) async {
    if (image == null || isReadOnly) return null;
    final directory = Directory(
      p.join(root.path, metadataDirectoryName, 'chapters'),
    );
    final target = File(
      p.join(directory.path, '$fileId-$index.${image.extension}'),
    );
    try {
      if (await target.exists()) return target.path;
      await directory.create(recursive: true);
      await target.writeAsBytes(image.bytes, flush: true);
      return target.path;
    } on FileSystemException {
      // A picture that will not come out of the file is a picture nobody
      // sees, never a reason for the episode not to play.
      return null;
    }
  }

  String? workDirectoryPath(String workId) {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return null;
    return _portableWorkDirectory(sourcePath).path;
  }

  Future<Map<String, Object?>?> loadPortableReaderProfile({
    required String workId,
    required String deviceKey,
    required String readerKind,
  }) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return null;
    final file = File(
      p.join(_workSidecarDirectory(sourcePath).path, 'reader-settings.yaml'),
    );
    if (!await file.exists()) return null;
    try {
      final value = loadYaml(await file.readAsString());
      if (value is! Map) return null;
      final devices = value['devices'];
      if (devices is! Map) return null;
      final device = devices[deviceKey];
      if (device is! Map) return null;
      final profile = device[readerKind];
      return profile is Map
          ? Map<String, Object?>.from(profile.cast<Object?, Object?>())
          : null;
    } on FileSystemException {
      return null;
    } on YamlException {
      return null;
    }
  }

  Future<void> savePortableReaderProfile({
    required String workId,
    required String deviceKey,
    required String readerKind,
    required Map<String, Object?> profile,
  }) async {
    _ensureWritable();
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final directory = _workSidecarDirectory(sourcePath);
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'reader-settings.yaml'));
    var values = <String, Object?>{'format_version': 1};
    if (await file.exists()) {
      try {
        final decoded = loadYaml(await file.readAsString());
        if (decoded is Map) {
          values = Map<String, Object?>.from(decoded.cast<Object?, Object?>());
        }
      } on FileSystemException {
        // A new portable settings file can replace an unreadable old one.
      } on YamlException {
        // A malformed optional profile must not block the reader.
      }
    }
    final devices = values['devices'] is Map
        ? Map<String, Object?>.from(values['devices'] as Map)
        : <String, Object?>{};
    final device = devices[deviceKey] is Map
        ? Map<String, Object?>.from(devices[deviceKey] as Map)
        : <String, Object?>{};
    device[readerKind] = profile;
    devices[deviceKey] = device;
    values['devices'] = devices;
    final partial = File('${file.path}.part');
    await partial.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(values)}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }

  LibraryPlaybackProgress? loadProgress(String workId) =>
      _database.loadProgress(workId);

  /// One work as the list would show it — for refreshing a single row.
  /// One work, in the same shape [listWorks] hands them out.
  ///
  /// The absolute-path step is not optional decoration: without it the cover
  /// comes back as a vault-relative path, no file is found under it, and the
  /// work loses its picture the moment anything refreshes it on its own.
  LibraryWorkSummary? workSummary(String workId) {
    final work = _database.workSummary(workId);
    return work == null ? null : _withAbsoluteCoverPath(work);
  }

  List<LibraryPlaybackRevision> listProgressRevisions(String workId) =>
      _database.listProgressRevisions(workId);

  List<LibraryPlaybackRevision> listCheckpointRevisions(
    String workId, {
    int perDevice = 3,
  }) => _database.listCheckpointRevisions(workId, perDevice: perDevice);

  /// The position from elsewhere that is waiting to be answered, if any.
  LibraryProgressChoice? progressChoice(String workId, {String? userId}) =>
      _database.progressChoice(workId, userId: userId ?? 'default');

  List<String> worksWithProgressChoices({String? userId}) =>
      _database.worksWithProgressChoices(userId: userId ?? 'default');

  /// Keeps a position that was not taken, so it can be offered on opening.
  void recordProgressChoice(LibraryProgressChoice choice) {
    _ensureWritable();
    _database.recordProgressChoice(choice, userId: choice.userId);
  }

  void clearProgressChoice(String workId, {String? userId}) {
    _ensureWritable();
    _database.clearProgressChoice(workId, userId: userId ?? 'default');
  }

  /// Takes the position that was offered and makes it this device's.
  LibraryPlaybackProgress? takeProgressChoice(
    String workId, {
    String deviceId = 'desktop-local',
    String? userId,
  }) {
    _ensureWritable();
    final choice = progressChoice(workId, userId: userId);
    if (choice == null) return null;
    clearProgressChoice(workId, userId: userId);
    final fileId = choice.fileId;
    if (fileId == null) return null;
    return _database.saveMediaProgress(
      workId: workId,
      fileId: fileId,
      position: choice.position,
      finished: choice.finished,
      deviceId: deviceId,
      operationId: FundusId.generate(),
    );
  }

  LibraryPlaybackProgress restoreProgressRevision({
    required String workId,
    required int revision,
    String deviceId = 'desktop-local',
    String? operationId,
  }) {
    _ensureWritable();
    return _database.restoreProgressRevision(
      workId: workId,
      revision: revision,
      deviceId: deviceId,
      operationId: operationId ?? FundusId.generate(),
    );
  }

  /// What is known about the single files of a work — a podcast episode's
  /// own text and date, as the show's feed tells it.
  Map<String, FileDetail> fileDetails(String workId) =>
      _database.fileDetails(workId);

  void setFileDetail({
    required String workId,
    required String fileId,
    String? title,
    String? description,
    DateTime? publishedAt,
  }) {
    _ensureWritable();
    _database.setFileDetail(
      workId: workId,
      fileId: fileId,
      title: title,
      description: description,
      publishedAt: publishedAt,
    );
  }

  /// Marks a work as a favourite, or takes the mark back.
  void setFavourite({
    required String workId,
    required bool favourite,
    String userId = 'default',
  }) {
    _ensureWritable();
    _database.setFavourite(
      workId: workId,
      favourite: favourite,
      userId: userId,
    );
  }

  /// The files of a work somebody has ticked off.
  ///
  /// Separate from the position, because they answer different questions: the
  /// position is „wo war ich", this is „Folge 3 habe ich gesehen". A series is
  /// watched out of order often enough that one cannot stand in for the other.
  Set<String> finishedFiles(String workId, {String userId = 'default'}) =>
      _database.finishedFiles(workId, userId: userId);

  void setFileFinished({
    required String workId,
    required String fileId,
    required bool finished,
    String userId = 'default',
  }) {
    _ensureWritable();
    _database.setFileFinished(
      workId: workId,
      fileId: fileId,
      finished: finished,
      userId: userId,
    );
  }

  LibraryPlaybackProgress saveProgress({
    required String workId,
    required String fileId,
    required Duration position,
    Duration? duration,
    bool finished = false,
    String deviceId = 'desktop-local',
    String? operationId,
    bool checkpoint = false,
  }) => _database.saveProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    duration: duration,
    finished: finished,
    deviceId: deviceId,
    operationId: operationId ?? FundusId.generate(),
    checkpoint: checkpoint,
  );

  LibraryPlaybackProgress saveMediaProgress({
    required String workId,
    required String fileId,
    required MediaPosition position,
    bool finished = false,
    String deviceId = 'desktop-local',
    String? operationId,
    DateTime? updatedAt,
    bool checkpoint = false,
  }) => _database.saveMediaProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    finished: finished,
    deviceId: deviceId,
    operationId: operationId ?? FundusId.generate(),
    updatedAt: updatedAt,
    checkpoint: checkpoint,
  );

  /// Wer an einem Werk beteiligt ist, mit Bild, wo eines da ist.
  List<({String name, String role, String? imagePath})> peopleOf(
    String workId,
  ) => _database.peopleOf(workId);

  /// Schreibt die Beteiligten eines Werks neu.
  void replaceWorkPeople(
    String workId,
    List<({String name, String role, String? imagePath})> people,
  ) {
    _ensureWritable();
    _database.replaceWorkPeople(workId, people);
  }

  /// Der Pfad zum Bild einer Person, relativ zur Bibliothek.
  String? personImage(String name) => _database.personImage(name);

  /// Legt das Bild einer Person in der Bibliothek ab.
  ///
  /// In der Bibliothek und nicht bei der App: ein Gesicht gehört zum Bestand
  /// wie ein Cover, und ein Ordner, den man auf ein anderes Gerät trägt, soll
  /// ihn mitnehmen. Der Dateiname kommt aus dem Namen, damit dieselbe Person
  /// nicht zweimal liegt.
  Future<String> cachePersonImage({
    required String name,
    required Uint8List bytes,
    String extension = 'jpg',
  }) async {
    _ensureWritable();
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes');
    final safe = name.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '-',
    );
    final key = safe.isEmpty ? '${name.hashCode.abs()}' : safe;
    final normalized = extension.toLowerCase() == 'png' ? 'png' : 'jpg';
    final directory = Directory(
      p.join(root.path, metadataDirectoryName, 'people'),
    );
    await directory.create(recursive: true);
    final filename = '$key.$normalized';
    final target = File(p.join(directory.path, filename));
    await target.writeAsBytes(bytes, flush: true);
    final relative = p.posix.join(metadataDirectoryName, 'people', filename);
    _database.setPersonImage(name, relative);
    return relative;
  }

  Future<String> cacheGeneratedCover({
    required String workId,
    required Uint8List bytes,
    String extension = 'png',
  }) async {
    _ensureWritable();
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes');
    final normalizedExtension = extension.toLowerCase() == 'jpg'
        ? 'jpg'
        : 'png';
    final directory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    await directory.create(recursive: true);
    final filename = '$workId.document.$normalizedExtension';
    final target = File(p.join(directory.path, filename));
    await target.writeAsBytes(bytes, flush: true);
    _database.setGeneratedCoverPath(
      workId,
      p.posix.join(metadataDirectoryName, 'covers', filename),
    );
    return target.path;
  }

  /// Keeps a wide picture for a work.
  ///
  /// The stage and the head of a detail page are landscape; a cover is not.
  /// Blowing a 2:3 poster up to fill them and blurring the result is a
  /// stopgap — where a service knows the backdrop, it is kept beside the
  /// cover and used instead.
  Future<String> cacheBackdrop({
    required String workId,
    required Uint8List bytes,
    String extension = 'jpg',
  }) async {
    _ensureWritable();
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes');
    final normalizedExtension = extension.toLowerCase() == 'png'
        ? 'png'
        : 'jpg';
    final directory = Directory(
      p.join(root.path, metadataDirectoryName, 'backdrops'),
    );
    await directory.create(recursive: true);
    final filename = '$workId.backdrop.$normalizedExtension';
    final target = File(p.join(directory.path, filename));
    await target.writeAsBytes(bytes, flush: true);
    _database.setBackdropPath(
      workId,
      p.posix.join(metadataDirectoryName, 'backdrops', filename),
    );
    return target.path;
  }

  PlaybackSession savePlaybackSession(
    PlaybackSession session, {
    String userId = 'default',
    String deviceId = 'desktop-local',
    int? expectedRevision,
  }) {
    _ensureWritable();
    return _database.savePlaybackSession(
      session,
      userId: userId,
      deviceId: deviceId,
      expectedRevision: expectedRevision,
    );
  }

  PlaybackSession? loadPlaybackSession(String sessionId) =>
      _database.loadPlaybackSession(sessionId);

  PlaybackSession? latestPlaybackSession({String userId = 'default'}) =>
      _database.latestPlaybackSession(userId: userId);

  /// Welche Werke seit [since] einen neuen Stand haben — die eine Frage, mit
  /// der ein Gerät herausfindet, was es nachziehen muss.
  List<({String workId, DateTime updatedAt})> progressChangedSince(
    DateTime? since, {
    int limit = 500,
  }) => _database.progressChangedSince(since, limit: limit);

  /// Welche Werke überhaupt etwas haben, das sich abgleichen ließe — ein
  /// Stand, eine Notiz, ein Lesezeichen, ein Schlagwort.
  Set<String> worksWorthSyncing() => _database.worksWorthSyncing();

  /// Was ein Werk belegt und wie groß sein Bild ist.
  ({int bytes, int? width, int? height, int files}) workStorage(
    String workId,
  ) => _database.workStorage(workId);

  /// Wohin die Terabyte gegangen sind — eine Zeile je Art von Werk.
  List<({String kind, int works, int files, int bytes})> storageByKind() =>
      _database.storageByKind();

  /// Wie viel im Katalog auf nichts mehr zeigt.
  ({int missingFiles, int emptyWorks}) orphanCount() => _database.orphanCount();

  /// Räumt weg, was auf nichts mehr zeigt, und sagt, wie viel es war.
  ({int files, int works}) removeOrphans() => _database.removeOrphans();

  /// Wie groß die Katalogdatei selbst ist.
  int catalogueBytes() {
    final file = _databaseFile(root);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  /// Verdichtet die Katalogdatei und sagt, was das gebracht hat.
  ({int before, int after}) compactCatalogue() {
    final before = catalogueBytes();
    _database.compact();
    return (before: before, after: catalogueBytes());
  }

  /// Wo in jeder Datei eines Werks jemand steht — für Werke, deren Dateien
  /// für sich stehen (eine Podcast-Folge, nicht das Kapitel eines Hörbuchs).
  Map<String, ({double position, double? total, DateTime updatedAt})>
  filePositions(String workId) => _database.filePositions(workId);

  void saveFilePosition({
    required String workId,
    required String fileId,
    required double position,
    double? total,
  }) {
    if (isReadOnly) return;
    _database.saveFilePosition(
      workId: workId,
      fileId: fileId,
      position: position,
      total: total,
    );
  }

  void clearFilePosition({required String workId, required String fileId}) {
    if (isReadOnly) return;
    _database.clearFilePosition(workId: workId, fileId: fileId);
  }

  List<LibraryPlaylist> listPlaylists() => _database.listPlaylists();

  LibraryPlaylist? loadPlaylist(String playlistId) =>
      _database.loadPlaylist(playlistId);

  LibraryPlaylist savePlaylist({
    String? playlistId,
    required String name,
    List<String> workIds = const [],
    List<PlaylistEntry>? entries,
    String? mediaType,
  }) {
    _ensureWritable();
    return _database.savePlaylist(
      playlistId: playlistId,
      name: name,
      workIds: workIds,
      entries: entries,
      mediaType: mediaType,
    );
  }

  /// Puts one work — or one file of it — at the end of a list.
  ///
  /// Adding the same thing twice is not an error and not a duplicate: a list
  /// somebody built by hand should not silently grow a second copy of a
  /// track, so an entry that is already in the list stays where it is.
  LibraryPlaylist addToPlaylist({
    required String playlistId,
    required PlaylistEntry entry,
  }) {
    _ensureWritable();
    final playlist = _database.loadPlaylist(playlistId);
    if (playlist == null) throw StateError('Liste wurde nicht gefunden.');
    if (playlist.entries.contains(entry)) return playlist;
    return _database.savePlaylist(
      playlistId: playlistId,
      name: playlist.name,
      entries: [...playlist.entries, entry],
      mediaType: playlist.mediaType,
    );
  }

  /// Takes the line at [index] out. Positions decide, not identity: the same
  /// track may legitimately be in a list twice.
  LibraryPlaylist removeFromPlaylist({
    required String playlistId,
    required int index,
  }) {
    _ensureWritable();
    final playlist = _database.loadPlaylist(playlistId);
    if (playlist == null) throw StateError('Liste wurde nicht gefunden.');
    if (index < 0 || index >= playlist.entries.length) return playlist;
    final entries = [...playlist.entries]..removeAt(index);
    return _database.savePlaylist(
      playlistId: playlistId,
      name: playlist.name,
      entries: entries,
      mediaType: playlist.mediaType,
    );
  }

  /// Moves a line, the way a finger drags it: taken out at [from] and put
  /// back at [to] in the list that no longer contains it.
  LibraryPlaylist reorderPlaylist({
    required String playlistId,
    required int from,
    required int to,
  }) {
    _ensureWritable();
    final playlist = _database.loadPlaylist(playlistId);
    if (playlist == null) throw StateError('Liste wurde nicht gefunden.');
    final entries = [...playlist.entries];
    if (from < 0 || from >= entries.length) return playlist;
    final entry = entries.removeAt(from);
    entries.insert(to.clamp(0, entries.length), entry);
    return _database.savePlaylist(
      playlistId: playlistId,
      name: playlist.name,
      entries: entries,
      mediaType: playlist.mediaType,
    );
  }

  /// Renames a list without touching what is in it.
  LibraryPlaylist renamePlaylist({
    required String playlistId,
    required String name,
  }) {
    _ensureWritable();
    final playlist = _database.loadPlaylist(playlistId);
    if (playlist == null) throw StateError('Liste wurde nicht gefunden.');
    return _database.savePlaylist(
      playlistId: playlistId,
      name: name,
      entries: playlist.entries,
      mediaType: playlist.mediaType,
    );
  }

  /// Übernimmt eine Liste, wie sie auf einem anderen Gerät steht — mit ihrer
  /// Fassungsnummer, damit ein Abgleich sich nicht selbst hochzählt.
  void adoptPlaylist(LibraryPlaylist playlist) {
    _ensureWritable();
    _database.adoptPlaylist(playlist);
  }

  void deletePlaylist(String playlistId) {
    _ensureWritable();
    _database.deletePlaylist(playlistId);
  }

  WorkAnnotations loadAnnotations(String workId) =>
      _database.loadAnnotations(workId);

  List<String> listTags() => _database.listTags();

  Future<LibraryWorkSummary> updateWorkMetadata({
    required String workId,
    required String title,
    required List<String> authors,
    String? subtitle,
    String? series,
    double? seriesSequence,
    List<String> narrators = const [],
    String? language,
    String? description,
    String? publisher,
    int? publishedYear,
    String? contentSensitivity,
    List<String>? genres,
    String? contentStyle,
    Map<String, String>? externalIds,
    WorkMetadataSource source = WorkMetadataSource.user,
  }) async {
    _ensureWritable();
    _database.updateWorkMetadata(
      workId: workId,
      title: title,
      authors: authors,
      subtitle: subtitle,
      series: series,
      seriesSequence: seriesSequence,
      narrators: narrators,
      language: language,
      description: description,
      publisher: publisher,
      publishedYear: publishedYear,
      contentSensitivity: contentSensitivity,
      genres: genres,
      contentStyle: contentStyle,
      externalIds: externalIds,
      source: source,
    );
    await _writeMetadataSidecar(workId);
    return listWorks(
      includeMissing: true,
    ).firstWhere((work) => work.id == workId);
  }

  Future<LibraryWorkSummary> updateWorkKind({
    required String workId,
    required String kind,
    String? contentStyle,
    String? contentSensitivity,
  }) async {
    _ensureWritable();
    _database.updateWorkKind(
      workId: workId,
      kind: kind,
      contentStyle: contentStyle,
      contentSensitivity: contentSensitivity,
    );
    await _writeMetadataSidecar(workId);
    return listWorks(
      includeMissing: true,
    ).firstWhere((work) => work.id == workId);
  }

  Future<WorkAnnotations> replaceWorkTags(
    String workId,
    Iterable<String> tags,
  ) async {
    _ensureWritable();
    _database.replaceWorkTags(workId, tags);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> saveWorkNote(String workId, String markdown) async {
    _ensureWritable();
    final normalized = markdown.trim();
    if (normalized.isEmpty) return loadAnnotations(workId);
    _database.saveWorkNote(workId, normalized);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addBookmark({
    required String workId,
    required String fileId,
    required Duration position,
    String? label,
    String? note,
  }) async {
    _ensureWritable();
    _database.addBookmark(
      workId: workId,
      fileId: fileId,
      position: position,
      label: label,
      note: note,
    );
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addMediaBookmark({
    required String workId,
    required String fileId,
    required MediaPosition position,
    String? label,
    String? note,
  }) async {
    _ensureWritable();
    _database.addMediaBookmark(
      workId: workId,
      fileId: fileId,
      mediaPosition: position,
      label: label,
      note: note,
    );
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> deleteBookmark(
    String workId,
    String bookmarkId,
  ) async {
    _ensureWritable();
    _database.deleteBookmark(bookmarkId);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addTextHighlight({
    required String workId,
    required String fileId,
    required MediaPosition position,
    required String quote,
    String color = '#FFF176',
    String? note,
  }) async {
    _ensureWritable();
    if (quote.trim().isEmpty) return loadAnnotations(workId);
    _database.addTextHighlight(
      workId: workId,
      fileId: fileId,
      mediaPosition: position,
      quote: quote,
      color: color,
      note: note,
    );
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> deleteHighlight(
    String workId,
    String highlightId,
  ) async {
    _ensureWritable();
    _database.deleteHighlight(highlightId);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  /// Reads the vault and brings the index up to date.
  ///
  /// By default this is a *check*, not a re-read: every file is stated, and
  /// one whose size and time already match the index is never opened. Only
  /// the works something happened to are imported again. A library where
  /// nothing changed therefore costs one walk of the tree instead of reading
  /// headers out of every audio file, opening every EPUB and rewriting every
  /// row — which is the difference between seconds and the several minutes a
  /// full pass takes.
  ///
  /// [full] forces the old behaviour, for when the index itself is suspect.
  /// [subtree] limits the pass to one folder; deletions are then only judged
  /// inside it, because nothing outside it was looked at.
  Stream<LibraryIndexEvent> index({
    LibraryScanner? scanner,
    AbsImporter? importer,
    ScanCancellationToken? cancellationToken,
    bool full = false,
    String? subtree,
  }) async* {
    if (isReadOnly) {
      throw StateError('Die Bibliothek ist schreibgeschützt.');
    }
    final delta = !full && !await _folderAssignmentChanged();
    final scope = subtree == null || subtree.trim().isEmpty
        ? null
        : p.posix.joinAll(MediaAreaMap.splitPath(subtree));
    final stamps = delta
        ? _database.indexedFileStamps()
        : const <String, ({int size, int modifiedAt})>{};
    final files = <ScannedFile>[];
    // Folders that refused to open, as paths relative to the vault.
    final unreadable = <String>[];
    // The walk goes to a worker unless a test hands in a scanner of its own.
    //
    // Stating ten thousand files on a network share takes minutes, and on
    // this isolate those are minutes in which nothing repaints and no button
    // answers. Nothing about the walk needs to be here: it is file system
    // work whose result is a plain list of records.
    if (scanner == null) {
      yield LibraryIndexEvent(phase: LibraryIndexPhase.scanning, fileCount: 0);
      await for (final batch in scanInBackground(
        root,
        known: delta ? stamps : const {},
        subtree: scope,
        cancellationToken: cancellationToken,
      )) {
        files.addAll(batch.files);
        for (final folder in batch.unreadable) {
          final relative = p.relative(folder, from: root.absolute.path);
          if (relative == '.' || relative.startsWith('..')) continue;
          unreadable.add(p.posix.joinAll(p.split(relative)));
        }
        if (cancellationToken?.isCancelled ?? false) {
          yield LibraryIndexEvent(
            phase: LibraryIndexPhase.cancelled,
            fileCount: files.length,
          );
          return;
        }
        yield LibraryIndexEvent(
          phase: LibraryIndexPhase.scanning,
          fileCount: files.length,
          currentPath: batch.files.lastOrNull?.relativePath,
        );
      }
    } else {
      await for (final event in scanner.scan(
        root,
        cancellationToken: cancellationToken,
        subtree: scope,
        isUnchanged: delta
            ? (path, size, modifiedAt) {
                final known = stamps[path];
                return known != null &&
                    known.size == size &&
                    known.modifiedAt == modifiedAt.millisecondsSinceEpoch;
              }
            : null,
      )) {
        if (event.kind == ScanEventKind.file) files.add(event.file!);
        if (event.kind == ScanEventKind.error &&
            event.file == null &&
            event.path != null) {
          final relative = p.relative(event.path!, from: root.absolute.path);
          if (relative != '.' && !relative.startsWith('..')) {
            unreadable.add(p.posix.joinAll(p.split(relative)));
          }
        }
        if (event.kind == ScanEventKind.cancelled) {
          yield LibraryIndexEvent(
            phase: LibraryIndexPhase.cancelled,
            fileCount: files.length,
          );
          return;
        }
        if (event.kind == ScanEventKind.file ||
            event.kind == ScanEventKind.started) {
          yield LibraryIndexEvent(
            phase: LibraryIndexPhase.scanning,
            fileCount: files.length,
            currentPath: event.file?.relativePath,
          );
        }
      }
    }

    final seenPaths = {for (final file in files) file.relativePath};
    final changedPaths = {
      for (final file in files)
        if (!file.unchanged) file.relativePath,
    };
    // A file below a folder that would not open has not been judged at all.
    //
    // The sweep marks everything it did not meet as missing, and over a
    // network share a folder refuses to list now and then. One hiccup used to
    // strip a work of its cover — the file was still there, the walk simply
    // never got to look — and it stayed that way until the next full pass.
    bool judged(String path) =>
        !unreadable.any((folder) => path.startsWith('$folder/'));
    final vanished = [
      for (final path in stamps.keys)
        if (!seenPaths.contains(path) &&
            judged(path) &&
            (scope == null || path == scope || path.startsWith('$scope/')))
          path,
    ];
    // A work is imported again when one of its own files moved, or when
    // something below its folder is gone — a work that lost a chapter has to
    // be rewritten even though nothing it still holds changed.
    bool touched(String directory, Iterable<ScannedFile> members) {
      if (!delta) return true;
      if (members.any((file) => changedPaths.contains(file.relativePath))) {
        return true;
      }
      if (vanished.isEmpty) return false;
      final prefix = directory == '.' ? '' : '$directory/';
      return vanished.any(
        (path) => path == directory || path.startsWith(prefix),
      );
    }

    final groupedCandidates =
        (importer ??
                AbsImporter(
                  mediaRootNames: configuration.rootsFor('audiobook'),
                  areas: MediaAreaMap(configuration.mediaRoots),
                ))
            .group(files);
    final groupedDocumentCandidates = DocumentImporter(
      mediaRoots: configuration.mediaRoots,
    ).group(files);
    final rootCounts = scope != null
        ? const <String, int>{}
        : _countScannedFiles(
            files,
            (file) => p.posix.split(file.relativePath).firstOrNull ?? '(root)',
          );
    final extensionCounts = scope != null
        ? const <String, int>{}
        : _countScannedFiles(
            files,
            (file) => file.extension.isEmpty ? '(ohne Endung)' : file.extension,
          );
    final documentCandidates = <DocumentImportCandidate>[];
    for (final candidate in groupedDocumentCandidates) {
      if (!touched(candidate.directory, candidate.files)) continue;
      documentCandidates.add(await _withEpubMetadata(candidate));
    }
    final candidates = <AudiobookImportCandidate>[];
    final portableIdentities = <String, _PortableWorkIdentity>{};
    for (final grouped in groupedCandidates) {
      if (!touched(grouped.directory, grouped.audioFiles)) continue;
      final portable = await _readPortableIdentity(grouped);
      portableIdentities[grouped.directory] = portable;
      final withAbsMetadata = await _withAbsMetadata(grouped);
      if (portable.identity case final identity?) {
        candidates.add(
          withAbsMetadata.copyWith(
            identity: identity,
            metadataSource: WorkMetadataSource.sidecar,
          ),
        );
      } else if (withAbsMetadata.absMetadata == null &&
          grouped.usesFallbackIdentity) {
        candidates.add(await _withEmbeddedIdentity(withAbsMetadata));
      } else {
        candidates.add(withAbsMetadata);
      }
    }
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.importing,
      fileCount: files.length,
      workCount: groupedCandidates.length + groupedDocumentCandidates.length,
      changedWorkCount: candidates.length + documentCandidates.length,
      changedFileCount: changedPaths.length + vanished.length,
    );
    final indexedDocuments =
        <({DocumentImportCandidate candidate, String workId})>[];
    final indexedCandidates = _database.transaction(() {
      final ids = delta ? _database.indexedFileIds() : <String, String>{};
      final indexed = <({AudiobookImportCandidate candidate, String workId})>[];
      for (final file in files) {
        if (delta && file.unchanged) continue;
        ids[file.relativePath] = _database.upsertFile(file);
      }
      _database.markUnseenFilesMissing(
        seenPaths,
        below: scope,
        spare: unreadable,
      );
      for (final candidate in candidates) {
        final portableId = portableIdentities[candidate.directory]?.workId;
        indexed.add((
          candidate: candidate,
          workId: _database.upsertAudiobookCandidate(
            candidate,
            ids,
            preferredWorkId:
                portableId ?? _database.findMovedAudiobookWorkId(candidate),
          ),
        ));
      }
      for (final candidate in documentCandidates) {
        indexedDocuments.add((
          candidate: candidate,
          workId: _database.upsertDocumentCandidate(candidate, ids),
        ));
      }
      _database.markWorksWithoutAvailableContentMissing();
      return indexed;
    });
    for (final indexed in indexedDocuments) {
      await _cachePublicationCover(indexed.candidate, indexed.workId);
      await _importAnnotationSidecars(
        indexed.candidate.directory,
        indexed.workId,
      );
    }
    for (final indexed in indexedCandidates) {
      try {
        await _importLanguage(indexed.candidate, indexed.workId);
      } on FileSystemException {
        // A broken metadata source must not hide the complete library.
      } on YamlException {
        // The user can repair malformed language metadata and scan again.
      } on FormatException {
        // Invalid source JSON is ignored until repaired.
      }
      try {
        await _importAnnotationSidecars(
          indexed.candidate.directory,
          indexed.workId,
        );
      } on FileSystemException {
        // A broken sidecar must not make the complete library unavailable.
      } on YamlException {
        // The user can repair malformed portable metadata and scan again.
      }
      await _importAbsTags(indexed.candidate, indexed.workId);
      await _cacheEmbeddedCover(indexed.candidate, indexed.workId);
      if (portableIdentities[indexed.candidate.directory]?.writable ?? false) {
        await _writeMetadataSidecar(indexed.workId);
      }
    }
    if (scope == null) await _rememberFolderAssignment();
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.completed,
      fileCount: files.length,
      unreadableFolders: List.unmodifiable(unreadable),
      workCount: groupedCandidates.length + groupedDocumentCandidates.length,
      changedWorkCount: candidates.length + documentCandidates.length,
      changedFileCount: changedPaths.length + vanished.length,
      rootCounts: rootCounts,
      extensionCounts: extensionCounts,
    );
  }

  static Map<String, int> _countScannedFiles(
    Iterable<ScannedFile> files,
    String Function(ScannedFile file) keyFor,
  ) {
    final counts = <String, int>{};
    for (final file in files) {
      final key = keyFor(file);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    return {for (final entry in entries) entry.key: entry.value};
  }

  Future<DocumentImportCandidate> _withEpubMetadata(
    DocumentImportCandidate candidate,
  ) async {
    if (candidate.kind != 'ebook' && candidate.kind != 'webnovel') {
      return candidate;
    }
    final source = candidate.files
        .where((file) => file.extension.toLowerCase() == 'epub')
        .firstOrNull;
    if (source == null) return candidate;
    try {
      final publication = await const EpubPackageAdapter().openFile(
        source.absolutePath,
      );
      return candidate.copyWith(
        title: publication.title,
        metadata: {
          if (publication.authors.isNotEmpty)
            'author': publication.authors.join(', '),
          if (publication.authors.isNotEmpty) 'authors': publication.authors,
          if (publication.languages.isNotEmpty)
            'language': publication.languages.first,
          'description': ?publication.description,
          if (publication.subjects.isNotEmpty) 'genres': publication.subjects,
          if (publication.publishers.isNotEmpty)
            'publisher': publication.publishers.join(', '),
        },
        embeddedCoverBytes: candidate.coverFile == null
            ? publication.coverBytes
            : null,
        embeddedCoverMimeType: candidate.coverFile == null
            ? publication.coverMimeType
            : null,
      );
    } on FileSystemException {
      return candidate;
    } on EpubPackageException {
      return candidate;
    }
  }

  Future<void> _cachePublicationCover(
    DocumentImportCandidate candidate,
    String workId,
  ) async {
    if (candidate.coverFile != null) return;
    final bytes = candidate.embeddedCoverBytes;
    if (bytes == null || bytes.isEmpty) return;
    final extension = switch (candidate.embeddedCoverMimeType?.toLowerCase()) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/jpeg' || 'image/jpg' => 'jpg',
      _ => null,
    };
    if (extension == null) return;
    final coverDirectory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    try {
      await coverDirectory.create(recursive: true);
      final filename = '$workId.$extension';
      await File(
        p.join(coverDirectory.path, filename),
      ).writeAsBytes(bytes, flush: true);
      _database.setGeneratedCoverPath(
        workId,
        p.posix.join(metadataDirectoryName, 'covers', filename),
      );
    } on FileSystemException {
      // Metadata remains usable when an embedded cover cannot be cached.
    }
  }

  Future<AudiobookImportCandidate> _withAbsMetadata(
    AudiobookImportCandidate candidate,
  ) async {
    try {
      final metadata = await const AbsMetadataReader().read(
        File(
          p.join(_safeWorkDirectory(candidate.directory).path, 'metadata.json'),
        ),
      );
      if (metadata == null) return candidate;
      return candidate.copyWith(
        absMetadata: metadata,
        metadataSource: WorkMetadataSource.abs,
        identity: AbsBookIdentity(
          author: metadata.author ?? candidate.identity.author,
          title: metadata.title ?? candidate.identity.title,
          series: metadata.series ?? candidate.identity.series,
          sequence: metadata.sequence ?? candidate.identity.sequence,
        ),
      );
    } on FileSystemException {
      return candidate;
    } on FormatException {
      return candidate;
    }
  }

  Future<void> _importAbsTags(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final metadata = candidate.absMetadata;
    if (metadata == null) return;
    final existing = loadAnnotations(workId);
    if (existing.tags.isNotEmpty) return;
    final tags = {...metadata.tags, ...metadata.genres};
    if (tags.isEmpty) return;
    _database.replaceWorkTags(workId, tags);
  }

  Future<AudiobookImportCandidate> _withEmbeddedIdentity(
    AudiobookImportCandidate candidate,
  ) async {
    if (candidate.audioFiles.isEmpty) return candidate;
    try {
      final metadata = await const EmbeddedCoverExtractor().extractMetadata(
        File(candidate.audioFiles.first.absolutePath),
      );
      if (metadata.isEmpty) return candidate;
      final title = candidate.audioFiles.length > 1
          ? metadata.album ?? candidate.identity.title
          : metadata.title ?? metadata.album ?? candidate.identity.title;
      return candidate.copyWith(
        metadataSource: WorkMetadataSource.embedded,
        identity: AbsBookIdentity(
          author:
              metadata.albumArtist ??
              metadata.author ??
              candidate.identity.author,
          title: title,
          series: metadata.series ?? candidate.identity.series,
          sequence: metadata.part ?? candidate.identity.sequence,
        ),
      );
    } on FileSystemException {
      return candidate;
    } on FormatException {
      return candidate;
    }
  }

  void close() => _database.close();

  void _ensureWritable() {
    if (isReadOnly) {
      throw StateError('Die Bibliothek ist schreibgeschützt.');
    }
  }

  /// Turns the stored, vault-relative picture paths into absolute ones.
  ///
  /// A path that climbs out of the vault is dropped rather than followed: the
  /// catalogue is data, and data does not get to name a file on the rest of
  /// the disk.
  LibraryWorkSummary _withAbsoluteCoverPath(LibraryWorkSummary work) {
    if (work.coverPath == null && work.backdropPath == null) return work;
    return work.withPictures(
      coverPath: _insideVault(work.coverPath),
      backdropPath: _insideVault(work.backdropPath),
    );
  }

  String? _insideVault(String? relative) {
    if (relative == null) return null;
    final absolute = p.normalize(p.join(root.path, relative));
    return p.isWithin(root.path, absolute) ? absolute : null;
  }

  Future<void> _cacheEmbeddedCover(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final coverDirectory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    if (candidate.coverFiles.isNotEmpty) {
      final source = candidate.coverFiles.first;
      final extension = source.extension == 'png' ? 'png' : 'jpg';
      try {
        await coverDirectory.create(recursive: true);
        final filename = '$workId.$extension';
        await File(
          source.absolutePath,
        ).copy(p.join(coverDirectory.path, filename));
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', filename),
        );
        return;
      } on FileSystemException {
        // An unreadable external cover can still fall back to embedded artwork.
      }
    }
    for (final extension in const ['jpg', 'png']) {
      final existing = File(p.join(coverDirectory.path, '$workId.$extension'));
      if (await existing.exists()) {
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', '$workId.$extension'),
        );
        return;
      }
    }

    const extractor = EmbeddedCoverExtractor();
    for (final audio in candidate.audioFiles) {
      try {
        final cover = await extractor.extract(File(audio.absolutePath));
        if (cover == null) continue;
        await coverDirectory.create(recursive: true);
        final filename = '$workId.${cover.extension}';
        await File(
          p.join(coverDirectory.path, filename),
        ).writeAsBytes(cover.bytes, flush: true);
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', filename),
        );
        return;
      } on FileSystemException {
        // A single unreadable media file must not abort the complete scan.
      } on FormatException {
        // Invalid embedded metadata falls back to the placeholder artwork.
      }
    }
    _database.setGeneratedCoverPath(workId, null);
  }

  Future<void> _writeAnnotationSidecars(String workId) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final sidecarDirectory = _workSidecarDirectory(sourcePath);
    await sidecarDirectory.create(recursive: true);
    final annotations = loadAnnotations(workId);
    await File(
      p.join(sidecarDirectory.path, 'notes.md'),
    ).writeAsString(_serializeNotes(annotations.notes), flush: true);
    await _writeMetadataSidecar(workId);
    final tracksById = {
      for (final track in playbackTracks(workId))
        track.fileId: track.relativePath,
    };
    await File(p.join(sidecarDirectory.path, 'bookmarks.yaml')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format_version': 2,
        'bookmarks': [
          for (final bookmark in annotations.bookmarks)
            {
              'id': bookmark.id,
              'file_path': tracksById[bookmark.fileId],
              'position': bookmark.mediaPosition.toJson(),
              if (bookmark.mediaPosition.kind == MediaPositionKind.time)
                'position_ms': bookmark.position.inMilliseconds,
              'label': bookmark.label,
              'note': bookmark.note,
              'created_at': bookmark.createdAt.toUtc().toIso8601String(),
            },
        ],
        'highlights': [
          for (final highlight in annotations.highlights)
            {
              'id': highlight.id,
              'file_path': tracksById[highlight.fileId],
              'position': highlight.mediaPosition.toJson(),
              'quote': highlight.quote,
              'color': highlight.color,
              'note': highlight.note,
              'created_at': highlight.createdAt.toUtc().toIso8601String(),
            },
        ],
      }),
      flush: true,
    );
  }

  Future<_PortableWorkIdentity> _readPortableIdentity(
    AudiobookImportCandidate candidate,
  ) async {
    final file = File(
      p.joinAll([
        root.path,
        ...p.posix.split(candidate.directory),
        '_fundus',
        'meta.yaml',
      ]),
    );
    if (!await file.exists()) {
      return const _PortableWorkIdentity(writable: true);
    }
    try {
      final value = loadYaml(await file.readAsString());
      if (value is! Map) {
        return const _PortableWorkIdentity(writable: false);
      }
      final baseKind = value['base_kind'];
      if (baseKind != null && baseKind != 'audiobook') {
        return const _PortableWorkIdentity(writable: false);
      }
      final workId = value['work_id'];
      if (workId != null &&
          (workId is! String || !_uuidPattern.hasMatch(workId))) {
        return const _PortableWorkIdentity(writable: false);
      }
      final title = value['title'];
      final author = value['author'];
      final series = value['series'];
      final sequence = value['series_sequence'];
      final identity =
          title is String &&
              title.trim().isNotEmpty &&
              author is String &&
              author.trim().isNotEmpty
          ? AbsBookIdentity(
              title: title.trim(),
              author: author.trim(),
              series: series is String && series.trim().isNotEmpty
                  ? series.trim()
                  : null,
              sequence: sequence is num ? sequence.toDouble() : null,
            )
          : null;
      return _PortableWorkIdentity(
        workId: workId as String?,
        writable: true,
        identity: identity,
      );
    } on FileSystemException {
      return const _PortableWorkIdentity(writable: false);
    } on YamlException {
      return const _PortableWorkIdentity(writable: false);
    }
  }

  Future<void> _writeMetadataSidecar(String workId) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final directory = _workSidecarDirectory(sourcePath);
    await directory.create(recursive: true);
    final annotations = loadAnnotations(workId);
    final work = listWorks().where((work) => work.id == workId).firstOrNull;
    if (work == null) return;
    await File(p.join(directory.path, 'meta.yaml')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
        'format_version': 3,
        'work_id': workId,
        'base_kind': work.kind,
        'custom_type': null,
        'title': work.title,
        'author': work.author,
        'authors': work.authors,
        'subtitle': work.subtitle,
        'series': work.series,
        'series_sequence': work.seriesSequence,
        'narrators': work.narrators,
        'language': work.language,
        'description': work.description,
        'publisher': work.publisher,
        'published_year': work.publishedYear,
        'content_sensitivity': work.contentSensitivity,
        'content_style': work.contentStyle,
        'genres': work.genres,
        'field_sources': {
          for (final entry in work.metadataOrigins.entries) entry.key: {'source': entry.value.source.name, 'updated_at': entry.value.updatedAt.toUtc().toIso8601String()},
        },
        'tags': annotations.tags,
      })}\n',
      flush: true,
    );
  }

  Future<void> _importAnnotationSidecars(
    String sourcePath,
    String workId,
  ) async {
    final sidecarDirectory = _workSidecarDirectory(sourcePath);
    if (!await sidecarDirectory.exists()) return;
    var annotations = loadAnnotations(workId);
    final noteFile = File(p.join(sidecarDirectory.path, 'notes.md'));
    if (annotations.notes.isEmpty && await noteFile.exists()) {
      final source = await noteFile.readAsString();
      final notes = _parseNotes(source);
      if (notes.isEmpty && source.trim().isNotEmpty) {
        _database.saveWorkNote(
          workId,
          source.trim(),
          updatedAt: await noteFile.lastModified(),
        );
      } else {
        for (final note in notes) {
          _database.saveWorkNote(
            workId,
            note.markdown,
            updatedAt: note.createdAt,
          );
        }
      }
    }
    final metaFile = File(p.join(sidecarDirectory.path, 'meta.yaml'));
    if (await metaFile.exists()) {
      final value = loadYaml(await metaFile.readAsString());
      if (value is Map) {
        if (annotations.tags.isEmpty && value['tags'] is List) {
          _database.replaceWorkTags(
            workId,
            (value['tags'] as List).whereType<String>(),
          );
        }
        final title = value['title'];
        final author = value['author'];
        final authors = value['authors'];
        if (title is String &&
            title.trim().isNotEmpty &&
            (author is String || authors is List)) {
          final fieldOrigins = _readFieldOrigins(value['field_sources']);
          _database.updateWorkMetadata(
            workId: workId,
            title: title,
            authors: authors is List && authors.whereType<String>().isNotEmpty
                ? authors.whereType<String>().toList(growable: false)
                : [author as String],
            subtitle: value['subtitle'] as String?,
            series: value['series'] as String?,
            seriesSequence: (value['series_sequence'] as num?)?.toDouble(),
            narrators: (value['narrators'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            language: value['language'] as String?,
            description: value['description'] as String?,
            publisher: value['publisher'] as String?,
            publishedYear: (value['published_year'] as num?)?.round(),
            contentSensitivity: _readContentSensitivity(
              value['content_sensitivity'],
            ),
            contentStyle: value['content_style'] as String?,
            genres: value['genres'] is List
                ? (value['genres'] as List).whereType<String>().toList(
                    growable: false,
                  )
                : null,
            source: WorkMetadataSource.sidecar,
            updatedAt: await metaFile.lastModified(),
            fieldOrigins: fieldOrigins,
          );
        }
      }
    }
    annotations = loadAnnotations(workId);
    final bookmarksFile = File(p.join(sidecarDirectory.path, 'bookmarks.yaml'));
    if (annotations.bookmarks.isEmpty && await bookmarksFile.exists()) {
      final value = loadYaml(await bookmarksFile.readAsString());
      final bookmarks = value is Map ? value['bookmarks'] : null;
      if (bookmarks is List) {
        final tracksByPath = {
          for (final track in playbackTracks(workId))
            track.relativePath: track.fileId,
        };
        for (final item in bookmarks.whereType<Map>()) {
          final fileId = tracksByPath[item['file_path']];
          if (fileId == null) continue;
          final id = item['id'];
          final label = item['label'];
          final note = item['note'];
          final createdAt = item['created_at'];
          final rawPosition = item['position'];
          if (rawPosition is Map) {
            try {
              final restored = MediaPosition.fromJson(
                rawPosition.cast<String, Object?>(),
              );
              _database.addMediaBookmark(
                id: id is String ? id : null,
                workId: workId,
                fileId: fileId,
                mediaPosition: restored.withFileId(fileId),
                label: label is String ? label : null,
                note: note is String ? note : null,
                createdAt: createdAt is String
                    ? DateTime.tryParse(createdAt)
                    : null,
              );
              continue;
            } catch (_) {
              // Fall back to the version-one time position below.
            }
          }
          final positionMs = item['position_ms'];
          if (positionMs is num) {
            _database.addBookmark(
              id: id is String ? id : null,
              workId: workId,
              fileId: fileId,
              position: Duration(milliseconds: positionMs.round()),
              label: label is String ? label : null,
              note: note is String ? note : null,
              createdAt: createdAt is String
                  ? DateTime.tryParse(createdAt)
                  : null,
            );
          }
        }
      }
    }
    annotations = loadAnnotations(workId);
    if (annotations.highlights.isEmpty && await bookmarksFile.exists()) {
      final value = loadYaml(await bookmarksFile.readAsString());
      final highlights = value is Map ? value['highlights'] : null;
      if (highlights is List) {
        final tracksByPath = {
          for (final track in playbackTracks(workId))
            track.relativePath: track.fileId,
        };
        for (final item in highlights.whereType<Map>()) {
          final fileId = tracksByPath[item['file_path']];
          final rawPosition = item['position'];
          final quote = item['quote'];
          if (fileId == null || rawPosition is! Map || quote is! String) {
            continue;
          }
          try {
            _database.addTextHighlight(
              id: item['id'] as String?,
              workId: workId,
              fileId: fileId,
              mediaPosition: MediaPosition.fromJson(
                rawPosition.cast<String, Object?>(),
              ).withFileId(fileId),
              quote: quote,
              color: item['color'] as String? ?? '#FFF176',
              note: item['note'] as String?,
              createdAt: item['created_at'] is String
                  ? DateTime.tryParse(item['created_at'] as String)
                  : null,
            );
          } on FormatException {
            // Ignore one malformed portable highlight.
          }
        }
      }
    }
  }

  static String? _readContentSensitivity(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim();
    return FundusDatabase.supportedContentSensitivities.contains(normalized)
        ? normalized
        : null;
  }

  static Map<String, WorkMetadataOrigin> _readFieldOrigins(Object? value) {
    if (value is! Map) return const {};
    final result = <String, WorkMetadataOrigin>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final raw = entry.value as Map;
      final sourceName = raw['source']?.toString();
      WorkMetadataSource? source;
      for (final candidate in WorkMetadataSource.values) {
        if (candidate.name == sourceName) source = candidate;
      }
      final updatedAt = DateTime.tryParse(raw['updated_at']?.toString() ?? '');
      if (source != null && updatedAt != null) {
        result[entry.key as String] = WorkMetadataOrigin(
          source: source,
          updatedAt: updatedAt.toUtc(),
        );
      }
    }
    return result;
  }

  Future<void> _importLanguage(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final workDirectory = _safeWorkDirectory(candidate.directory);
    final fundusMeta = File(p.join(workDirectory.path, '_fundus', 'meta.yaml'));
    if (await fundusMeta.exists()) {
      final value = loadYaml(await fundusMeta.readAsString());
      if (value is Map && value['language'] is String) {
        _database.setWorkLanguage(
          workId,
          value['language'] as String,
          source: WorkMetadataSource.sidecar,
          updatedAt: await fundusMeta.lastModified(),
        );
        return;
      }
    }

    final absLanguage = candidate.absMetadata?.language;
    if (absLanguage != null && absLanguage.trim().isNotEmpty) {
      _database.setWorkLanguage(
        workId,
        absLanguage,
        source: WorkMetadataSource.abs,
      );
      return;
    }

    final sourceFile = File(p.join(workDirectory.path, '_source.json'));
    if (await sourceFile.exists()) {
      final value = jsonDecode(await sourceFile.readAsString());
      if (value is Map) {
        final direct = value['language'];
        final metadata = value['metadata'];
        final nested = metadata is Map ? metadata['language'] : null;
        final language = direct is String
            ? direct
            : nested is String
            ? nested
            : null;
        if (language != null && language.trim().isNotEmpty) {
          _database.setWorkLanguage(
            workId,
            language,
            source: WorkMetadataSource.sidecar,
            updatedAt: await sourceFile.lastModified(),
          );
          return;
        }
      }
    }

    const extractor = EmbeddedCoverExtractor();
    for (final audio in candidate.audioFiles) {
      final file = File(audio.absolutePath);
      final metadata = await extractor.extractMetadata(file);
      final language =
          metadata.language ?? await extractor.extractLanguage(file);
      if (language == null || language.trim().isEmpty) continue;
      _database.setWorkLanguage(
        workId,
        language,
        source: WorkMetadataSource.embedded,
      );
      return;
    }
  }

  static String _serializeNotes(List<LibraryNote> notes) {
    if (notes.isEmpty) return '';
    return '${notes.map((note) {
      final local = note.createdAt.toLocal();
      final date = '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      return '<!-- fundus-note: ${note.createdAt.toUtc().toIso8601String()} -->\n'
          '## $date\n\n${note.markdown.trim()}';
    }).join('\n\n')}\n';
  }

  static List<({String markdown, DateTime createdAt})> _parseNotes(
    String source,
  ) {
    final marker = RegExp(r'<!-- fundus-note: ([^>]+) -->\s*\n## [^\n]*\n\s*');
    final matches = marker.allMatches(source).toList(growable: false);
    if (matches.isEmpty) return const [];
    final notes = <({String markdown, DateTime createdAt})>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final createdAt = DateTime.tryParse(match.group(1)!.trim());
      if (createdAt == null) continue;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : source.length;
      final markdown = source.substring(match.end, end).trim();
      if (markdown.isEmpty) continue;
      notes.add((markdown: markdown, createdAt: createdAt));
    }
    return notes;
  }

  Directory _safeWorkDirectory(String sourcePath) {
    final path = p.normalize(
      p.joinAll([root.path, ...p.posix.split(sourcePath)]),
    );
    final normalizedRoot = p.normalize(root.path);
    if (path != normalizedRoot && !p.isWithin(normalizedRoot, path)) {
      throw StateError('Unsicherer Werkpfad im Bibliotheksindex: $sourcePath');
    }
    return Directory(path);
  }

  Directory _portableWorkDirectory(String sourcePath) {
    final target = _safeWorkDirectory(sourcePath);
    return FileSystemEntity.isFileSync(target.path) ? target.parent : target;
  }

  Directory _workSidecarDirectory(String sourcePath) {
    final target = _safeWorkDirectory(sourcePath);
    if (!FileSystemEntity.isFileSync(target.path)) {
      return Directory(p.join(target.path, '_fundus'));
    }
    return Directory(
      p.join(target.parent.path, '_fundus', 'files', p.basename(target.path)),
    );
  }

  bool _usesPortableSidecars(String workId) =>
      listWorks(includeMissing: true).any((work) => work.id == workId);

  static File _manifestFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$manifestFileName');

  static File _databaseFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$databaseFileName');

  static File _configurationFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$configurationFileName');

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
}
