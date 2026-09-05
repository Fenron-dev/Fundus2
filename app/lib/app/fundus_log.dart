import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

enum LogLevel {
  debug('·'),
  info('i'),
  warn('!'),
  error('×');

  const LogLevel(this.mark);

  final String mark;
}

final class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.event,
    this.data = const {},
    this.took,
  });

  final DateTime at;
  final LogLevel level;
  final String event;
  final Map<String, Object?> data;

  /// How long the thing took, where the entry closes a span.
  final Duration? took;

  /// One line, in the shape somebody can read and paste.
  String get line {
    final time = at.toLocal().toIso8601String().substring(11, 23);
    final took = this.took == null ? '' : ' ${this.took!.inMilliseconds} ms';
    final rest = data.isEmpty
        ? ''
        : ' ${data.entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}';
    return '$time ${level.mark} $event$took$rest';
  }

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'level': level.name,
    'event': event,
    if (took != null) 'took_ms': took!.inMilliseconds,
    if (data.isNotEmpty) 'data': data,
  };
}

/// What the app did, and how long it took.
///
/// There was no way to answer „warum dauert das so lange?" except by
/// guessing. This keeps the last few hundred things that happened, with a
/// duration on the ones worth timing, so a slow start can be handed over as
/// evidence rather than described.
///
/// **No absolute media paths.** A log is meant to be sent to somebody; the
/// name of a file is enough to recognise it and the rest of the path is
/// nobody's business. [where] is the one way a path enters an entry, and it
/// keeps only the last two segments.
class FundusLog extends ChangeNotifier {
  FundusLog._();

  static final instance = FundusLog._();

  /// Enough to cover an app start and a slow open; short enough to read.
  static const capacity = 600;

  final Queue<LogEntry> _entries = Queue<LogEntry>();
  File? _file;
  Future<void> _writing = Future.value();
  bool _enabled = true;

  List<LogEntry> get entries => List.unmodifiable(_entries);
  bool get isEnabled => _enabled;
  File? get file => _file;

  /// Where the log is kept between starts — this installation's own storage,
  /// never the vault: a vault folder is shared, and this describes a device.
  Future<void> attach(Directory room) async {
    try {
      final target = File(p.join(room.path, 'fundus.log'));
      await target.parent.create(recursive: true);
      // One roll, so a long-running app cannot fill a disk.
      if (await target.exists() && await target.length() > 2 * 1024 * 1024) {
        await target.writeAsString('');
      }
      _file = target;
      write(LogLevel.info, 'log.attached');
    } on Object {
      // A log that cannot be written is still a log that can be read.
    }
  }

  void setEnabled(bool value) {
    _enabled = value;
    notifyListeners();
  }

  void write(
    LogLevel level,
    String event, [
    Map<String, Object?> data = const {},
    Duration? took,
  ]) {
    if (!_enabled) return;
    final entry = LogEntry(
      at: DateTime.now(),
      level: level,
      event: event,
      data: data,
      took: took,
    );
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    _append(entry);
    notifyListeners();
  }

  void info(String event, [Map<String, Object?> data = const {}]) =>
      write(LogLevel.info, event, data);

  void warn(String event, [Map<String, Object?> data = const {}]) =>
      write(LogLevel.warn, event, data);

  void error(
    String event,
    Object failure, [
    Map<String, Object?> data = const {},
  ]) => write(LogLevel.error, event, {...data, 'error': '$failure'});

  /// Runs [action] and records what it cost.
  ///
  /// The failure case is timed too — „it threw after nine seconds" is a
  /// different problem from „it threw at once", and the log is where that
  /// difference has to show.
  Future<T> time<T>(
    String event,
    Future<T> Function() action, [
    Map<String, Object?> data = const {},
  ]) async {
    final watch = Stopwatch()..start();
    try {
      final result = await action();
      write(LogLevel.info, event, data, watch.elapsed);
      return result;
    } on Object catch (failure) {
      write(LogLevel.error, event, {
        ...data,
        'error': '$failure',
      }, watch.elapsed);
      rethrow;
    }
  }

  /// Times a stretch of work that is not one call.
  LogSpan start(String event, [Map<String, Object?> data = const {}]) =>
      LogSpan._(this, event, data);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// The whole log as text, for the clipboard or a file.
  String render() => _entries.map((entry) => entry.line).join('\n');

  String renderJson() =>
      _entries.map((entry) => jsonEncode(entry.toJson())).join('\n');

  /// A path shortened to what is recognisable and nothing more.
  static String where(String path) {
    final parts = p.split(path.replaceAll('\\', '/'))
      ..removeWhere((part) => part.isEmpty);
    if (parts.length <= 2) return parts.join('/');
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  void _append(LogEntry entry) {
    final target = _file;
    if (target == null) return;
    _writing = _writing.then((_) async {
      try {
        await target.writeAsString(
          '${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append,
          flush: false,
        );
      } on Object {
        // The in-memory log is the one that matters; the file is a copy.
      }
    });
  }
}

/// A stretch of work being timed.
final class LogSpan {
  LogSpan._(this._log, this._event, this._data);

  final FundusLog _log;
  final String _event;
  final Map<String, Object?> _data;
  final Stopwatch _watch = Stopwatch()..start();

  /// Notes a step inside the span, with the time since it began.
  void step(String what, [Map<String, Object?> data = const {}]) => _log.write(
    LogLevel.debug,
    '$_event.$what',
    {..._data, ...data},
    _watch.elapsed,
  );

  void done([Map<String, Object?> data = const {}]) =>
      _log.write(LogLevel.info, _event, {..._data, ...data}, _watch.elapsed);

  void failed(Object failure) => _log.write(LogLevel.error, _event, {
    ..._data,
    'error': '$failure',
  }, _watch.elapsed);
}
