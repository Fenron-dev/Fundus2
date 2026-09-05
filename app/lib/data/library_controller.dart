import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';

import '../app/fundus_log.dart';
import 'work_view.dart';

enum LibraryStatus { idle, opening, ready, scanning, failed }

/// The one way the interface reaches the catalogue.
///
/// Every list, filter, sort and search is a query against the local index —
/// there is no HTTP in the scroll path, and no screen knows whether a work
/// came from this disk or from a peer. When peer catalogues are mirrored in,
/// they land in these same tables and nothing above this class changes.
class LibraryController extends ChangeNotifier {
  LibraryController();

  FundusLibrary? _library;
  ScanCancellationToken? _scanToken;

  LibraryStatus _status = LibraryStatus.idle;
  String? _error;
  List<WorkView> _works = const [];
  List<LibrarySource> _sources = const [];
  LibraryIndexEvent? _scanProgress;
  LibraryIndexEvent? _lastResult;
  DateTime? _lastCheckedAt;
  bool _lastScanWasFull = false;
  Map<String, int> _lastRootCounts = const {};
  Map<String, int> _worksPerMediaType = const {};
  Map<String, int> _worksPerSource = const {};
  int _unassignedWorks = 0;

  /// Works this must not hand out at all.
  ///
  /// Set by the scope from the protection mode. It sits here rather than in
  /// each screen because this is the one funnel every list, count, search and
  /// „Fortsetzen" comes through — a rule applied in twelve places is a rule
  /// that will be forgotten in one of them.
  bool Function(WorkView work)? hides;

  LibraryStatus get status => _status;
  String? get error => _error;
  List<WorkView> get works => _works;

  /// How many works each media type holds, and how many belong to no type.
  ///
  /// Worked out when the list changes rather than when something asks. The
  /// navigation column asks on every build, and every build used to walk the
  /// whole catalogue twice — with the interface rebuilding on any change at
  /// all, that is two passes over every work for a moved slider.
  Map<String, int> get worksPerMediaType => _worksPerMediaType;

  Map<String, int> get worksPerSource => _worksPerSource;
  int get unassignedWorkCount => _unassignedWorks;
  List<LibrarySource> get sources => _sources;
  LibraryIndexEvent? get scanProgress => _scanProgress;

  /// What the last finished pass found, for the one line that reports it.
  LibraryIndexEvent? get lastResult => _lastResult;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  bool get lastScanWasFull => _lastScanWasFull;
  FundusLibrary? get library => _library;

  /// Top-level folders the last scan walked past because no media area claims
  /// their name.
  ///
  /// The scanner only indexes below configured folders, so an area called
  /// "Anime" or a "Webnovels" folder later renamed to "Light Novels" simply
  /// yields nothing. Silence would be the worst answer; these folders are
  /// offered for assignment instead.
  Map<String, int> get unassignedFolders {
    final library = _library;
    if (library == null || _lastRootCounts.isEmpty) return const {};
    final known = library.configuredRootNames;
    return {
      for (final entry in _lastRootCounts.entries)
        if (entry.value > 0 &&
            !known.contains(entry.key.toLowerCase()) &&
            !_ignoredFolders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  static const _ignoredFolders = {
    '.library',
    '_fundus',
    '(root)',
    '.ds_store',
    '\$recycle.bin',
    'system volume information',
  };

  /// Assigns a folder to a media area and reads the library in again — the
  /// choice is stored with the vault, not with this device.
  Future<void> assignFolder(String folder, String configurationKind) async {
    final library = _library;
    if (library == null) return;
    await library.assignMediaRoot(folder: folder, kind: configurationKind);
    await scan();
  }

  bool get isOpen => _library != null;
  bool get isScanning => _status == LibraryStatus.scanning;

  String get displayName {
    final source = _sources.where((s) => s.isVault).firstOrNull;
    if (source != null && source.displayName.isNotEmpty) {
      return source.displayName;
    }
    final path = _library?.root.path;
    return path == null
        ? 'Keine Bibliothek'
        : path.split(Platform.pathSeparator).last;
  }

  String get locationLabel {
    final path = _library?.root.path;
    if (path == null) return '';
    return '$path · ${_works.length} Werke';
  }

  /// Opens an existing vault, or creates one in an empty folder.
  /// How long to wait for a folder to answer before giving up on it.
  ///
  /// A vault on a network share that is not mounted does not fail — it
  /// blocks, in a native call, for as long as the operating system feels
  /// like. Waiting forever looks exactly like working, which is the worst
  /// thing an opening library can look like.
  static const reachTimeout = Duration(seconds: 6);

  Future<void> open(Directory root, {bool createIfMissing = false}) async {
    _status = LibraryStatus.opening;
    _error = null;
    notifyListeners();
    try {
      if (!await _answers(root) && !createIfMissing) {
        _library = null;
        _works = const [];
        _sources = const [];
        _error = _unreachableMessage(root);
        _status = LibraryStatus.failed;
        notifyListeners();
        return;
      }
      _library?.close();
      _library =
          await (createIfMissing
                  ? FundusLibrary.create(root)
                  : FundusLibrary.open(root))
              .timeout(reachTimeout);
      _reload();
      _status = LibraryStatus.ready;
    } on TimeoutException {
      _library = null;
      _works = const [];
      _sources = const [];
      _error = _unreachableMessage(root);
      _status = LibraryStatus.failed;
    } on Object catch (failure) {
      _library = null;
      _works = const [];
      _sources = const [];
      _error = failure is FileSystemException
          ? failure.message
          : failure.toString();
      _status = LibraryStatus.failed;
    }
    notifyListeners();
  }

  /// Whether the folder answers at all, within a bounded wait.
  ///
  /// The wait is what matters: the call itself may still be sitting in the
  /// kernel afterwards, but this side has stopped pretending to work.
  Future<bool> _answers(Directory root) async {
    try {
      return await root.exists().timeout(reachTimeout);
    } on Object {
      return false;
    }
  }

  /// Says the one thing worth saying, and the likeliest reason.
  static String _unreachableMessage(Directory root) =>
      'Der Ordner „${root.path}" antwortet nicht. Liegt er auf einer '
      'Netzfreigabe, muss die erst verbunden sein — im Finder einmal '
      'öffnen genügt.';

  void close() {
    _scanToken?.cancel();
    _library?.close();
    _library = null;
    _works = const [];
    _sources = const [];
    _status = LibraryStatus.idle;
    notifyListeners();
  }

  /// Indexes the vault. The scan is interruptible and resumable — with a
  /// hundred thousand files it has to be.
  ///
  /// [full] re-reads everything; without it this is a check that only touches
  /// what changed. [subtree] narrows it to one folder.
  Future<void> scan({bool full = false, String? subtree}) async {
    final library = _library;
    if (library == null || _status == LibraryStatus.scanning) return;
    final token = ScanCancellationToken();
    _scanToken = token;
    _status = LibraryStatus.scanning;
    _scanProgress = null;
    _lastScanWasFull = full;
    notifyListeners();
    final span = FundusLog.instance.start('library.scan', {
      'full': full,
      'folder': ?subtree,
    });
    try {
      // A file counter that moves faster than an eye can read it is not
      // worth a rebuild of the whole interface. Every file still counts; the
      // screens hear about it four times a second, and always at the end.
      var told = DateTime.now();
      await for (final event in library.index(
        cancellationToken: token,
        full: full,
        subtree: subtree,
      )) {
        _scanProgress = event;
        if (event.rootCounts.isNotEmpty) _lastRootCounts = event.rootCounts;
        final settled =
            event.phase == LibraryIndexPhase.completed ||
            event.phase == LibraryIndexPhase.cancelled;
        if (settled) {
          _lastResult = event.phase == LibraryIndexPhase.completed
              ? event
              : null;
          _reload();
        }
        final now = DateTime.now();
        if (!settled &&
            now.difference(told) < const Duration(milliseconds: 250)) {
          continue;
        }
        told = now;
        notifyListeners();
      }
      _status = LibraryStatus.ready;
      _lastCheckedAt = DateTime.now();
      span.done({
        'files': _lastResult?.fileCount ?? 0,
        'changed_files': _lastResult?.changedFileCount ?? 0,
        'changed_works': _lastResult?.changedWorkCount ?? 0,
      });
    } on Object catch (failure) {
      span.failed(failure);
      _error = failure.toString();
      _status = LibraryStatus.failed;
    } finally {
      _scanToken = null;
      notifyListeners();
    }
  }

  /// Whether now is a bad moment to walk the whole folder.
  ///
  /// Set by the scope from what is open. A check is cheap next to a full
  /// re-read and still not free — over a network share it is thousands of
  /// round trips — and doing it under a playing film is the one place where
  /// the cost lands on something somebody is watching.
  bool Function()? busyElsewhere;

  /// Looks for changes without being asked.
  ///
  /// A library nobody touched costs one walk of the tree; there is no reason
  /// to make someone press a button to find out that a series they copied in
  /// half an hour ago exists. It stays quiet when a scan is already running,
  /// when something is being played or read, and when the last check is
  /// recent.
  ///
  /// „Recent" is deliberately long. On a desktop, every return of window
  /// focus counts as coming back to the app — clicking away to the Finder and
  /// back would otherwise start a walk of the whole vault, which is exactly
  /// the interruption this was supposed to save people.
  Future<void> checkForChanges({bool force = false}) async {
    if (_library == null || _status == LibraryStatus.scanning) return;
    if (!force) {
      if (busyElsewhere?.call() ?? false) {
        FundusLog.instance.write(LogLevel.debug, 'library.check.deferred');
        return;
      }
      if (_lastCheckedAt != null &&
          DateTime.now().difference(_lastCheckedAt!) < recheckAfter) {
        return;
      }
    }
    await scan();
  }

  /// How long a check stays good enough that another one is not worth it.
  static const recheckAfter = Duration(minutes: 30);

  void cancelScan() => _scanToken?.cancel();

  /// Reads the whole catalogue again. For after a scan, and little else.
  void refresh() {
    if (_library == null) return;
    _reload();
    notifyListeners();
  }

  /// Brings one work up to date, and leaves the rest of the catalogue alone.
  ///
  /// Playing or reading something changes exactly one row — its position, its
  /// „zuletzt geöffnet". Refreshing the whole list for that meant re-reading
  /// twelve thousand works, which on a vault over a network share is several
  /// seconds of database pages between pressing play and anything happening.
  void refreshWork(String workId) {
    final library = _library;
    if (library == null) return;
    final index = _works.indexWhere((work) => work.id == workId);
    final summary = library.workSummary(workId);
    if (summary == null) {
      if (index < 0) return;
      final rest = [..._works]..removeAt(index);
      _works = List.unmodifiable(rest);
      _countWorks();
      notifyListeners();
      return;
    }
    final view = WorkView.fromSummary(summary);
    if (hides?.call(view) ?? false) {
      if (index < 0) return;
      final rest = [..._works]..removeAt(index);
      _works = List.unmodifiable(rest);
      _countWorks();
      notifyListeners();
      return;
    }
    final next = [..._works];
    if (index < 0) {
      next.add(view);
    } else {
      next[index] = view;
    }
    _works = List.unmodifiable(next);
    _countWorks();
    notifyListeners();
  }

  WorkView? workById(String id) {
    for (final work in _works) {
      if (work.id == id) return work;
    }
    return null;
  }

  void _reload() {
    final library = _library;
    if (library == null) return;
    // `includeMissing` on purpose: a file that is gone is a state to show, not
    // a row to hide — the origin mark says "nicht erreichbar" and the work
    // keeps its notes, rating and progress.
    final gate = hides;
    _works = library
        .listWorks(includeMissing: true)
        .map(WorkView.fromSummary)
        .where((work) => gate == null || !gate(work))
        .toList(growable: false);
    _sources = library.listSources();
    _scanProgress = null;
    _countWorks();
  }

  void _countWorks() {
    final byType = <String, int>{};
    final bySource = <String, int>{};
    var unassigned = 0;
    for (final work in _works) {
      final type = work.mediaType;
      if (type == null) {
        unassigned++;
      } else {
        byType[type.id] = (byType[type.id] ?? 0) + 1;
      }
      final source = work.summary.sourceId;
      bySource[source] = (bySource[source] ?? 0) + 1;
    }
    _worksPerMediaType = Map.unmodifiable(byType);
    _worksPerSource = Map.unmodifiable(bySource);
    _unassignedWorks = unassigned;
  }

  @override
  void dispose() {
    _scanToken?.cancel();
    _library?.close();
    super.dispose();
  }
}
