import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';

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
  Map<String, int> _lastRootCounts = const {};

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
  List<LibrarySource> get sources => _sources;
  LibraryIndexEvent? get scanProgress => _scanProgress;
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
  Future<void> scan() async {
    final library = _library;
    if (library == null || _status == LibraryStatus.scanning) return;
    final token = ScanCancellationToken();
    _scanToken = token;
    _status = LibraryStatus.scanning;
    _scanProgress = null;
    notifyListeners();
    try {
      await for (final event in library.index(cancellationToken: token)) {
        _scanProgress = event;
        if (event.rootCounts.isNotEmpty) _lastRootCounts = event.rootCounts;
        if (event.phase == LibraryIndexPhase.completed ||
            event.phase == LibraryIndexPhase.cancelled) {
          _reload();
        }
        notifyListeners();
      }
      _status = LibraryStatus.ready;
    } on Object catch (failure) {
      _error = failure.toString();
      _status = LibraryStatus.failed;
    } finally {
      _scanToken = null;
      notifyListeners();
    }
  }

  void cancelScan() => _scanToken?.cancel();

  void refresh() {
    if (_library == null) return;
    _reload();
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
  }

  @override
  void dispose() {
    _scanToken?.cancel();
    _library?.close();
    super.dispose();
  }
}
