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

  LibraryStatus get status => _status;
  String? get error => _error;
  List<WorkView> get works => _works;
  List<LibrarySource> get sources => _sources;
  LibraryIndexEvent? get scanProgress => _scanProgress;
  FundusLibrary? get library => _library;

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
  Future<void> open(Directory root, {bool createIfMissing = false}) async {
    _status = LibraryStatus.opening;
    _error = null;
    notifyListeners();
    try {
      _library?.close();
      _library = createIfMissing
          ? await FundusLibrary.create(root)
          : await FundusLibrary.open(root);
      _reload();
      _status = LibraryStatus.ready;
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
    _works = library
        .listWorks(includeMissing: true)
        .map(WorkView.fromSummary)
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
