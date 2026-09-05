import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'library_scanner.dart';

/// What the worker is told to do.
final class _ScanRequest {
  const _ScanRequest({
    required this.reply,
    required this.rootPath,
    required this.known,
    required this.ignoredDirectoryNames,
    required this.ignoredFileNames,
    this.subtree,
  });

  final SendPort reply;
  final String rootPath;
  final Map<String, ({int size, int modifiedAt})> known;
  final Set<String> ignoredDirectoryNames;
  final Set<String> ignoredFileNames;
  final String? subtree;
}

/// A batch of results on their way back.
final class ScanBatch {
  const ScanBatch({
    required this.files,
    required this.visited,
    this.done = false,
    this.error,
  });

  final List<ScannedFile> files;
  final int visited;
  final bool done;
  final Object? error;
}

/// Walks the vault on a worker isolate.
///
/// Ten thousand files on a network share is ten thousand round trips, and on
/// the interface's own isolate that is minutes during which nothing repaints
/// and no button answers — „er dreht sich erstmal einen Moment" is exactly
/// this. The walk is pure file system work with a plain list of records as
/// its result, so it belongs on a worker; the database side stays where the
/// database is.
///
/// Results come back in batches rather than one message per file: ten
/// thousand port messages would move the cost rather than remove it.
Stream<ScanBatch> scanInBackground(
  Directory root, {
  Map<String, ({int size, int modifiedAt})> known = const {},
  String? subtree,
  ScanCancellationToken? cancellationToken,
  LibraryScanner? scanner,
}) {
  final controller = StreamController<ScanBatch>();
  final receive = ReceivePort();
  final template = scanner ?? LibraryScanner();
  Isolate? worker;
  var closed = false;

  Future<void> finish() async {
    if (closed) return;
    closed = true;
    receive.close();
    worker?.kill(priority: Isolate.immediate);
    await controller.close();
  }

  receive.listen((message) {
    if (message is! ScanBatch) return;
    if (!controller.isClosed) controller.add(message);
    if (message.done) unawaited(finish());
    if (cancellationToken?.isCancelled ?? false) unawaited(finish());
  });

  controller.onCancel = finish;
  unawaited(() async {
    try {
      worker = await Isolate.spawn(
        _scanEntry,
        _ScanRequest(
          reply: receive.sendPort,
          rootPath: root.absolute.path,
          known: known,
          ignoredDirectoryNames: template.ignoredDirectoryNames,
          ignoredFileNames: template.ignoredFileNames,
          subtree: subtree,
        ),
        errorsAreFatal: true,
        onError: receive.sendPort,
        onExit: receive.sendPort,
      );
    } on Object catch (error) {
      if (!controller.isClosed) {
        controller.add(
          ScanBatch(files: const [], visited: 0, done: true, error: error),
        );
      }
      await finish();
    }
  }());

  return controller.stream;
}

Future<void> _scanEntry(_ScanRequest request) async {
  final scanner = LibraryScanner(
    ignoredDirectoryNames: request.ignoredDirectoryNames,
    ignoredFileNames: request.ignoredFileNames,
  );
  final batch = <ScannedFile>[];
  var visited = 0;
  Object? failure;
  try {
    await for (final event in scanner.scan(
      Directory(request.rootPath),
      subtree: request.subtree,
      isUnchanged: (path, size, modifiedAt) {
        final stamp = request.known[path];
        return stamp != null &&
            stamp.size == size &&
            stamp.modifiedAt == modifiedAt.millisecondsSinceEpoch;
      },
    )) {
      if (event.kind == ScanEventKind.file) {
        batch.add(event.file!);
        visited = event.visitedFiles;
        if (batch.length >= 200) {
          request.reply.send(
            ScanBatch(files: List.of(batch), visited: visited),
          );
          batch.clear();
        }
      }
      if (event.kind == ScanEventKind.error && event.file == null) {
        // A folder that cannot be read is reported once and walked past.
        failure ??= event.error;
      }
    }
  } on Object catch (error) {
    failure = error;
  }
  request.reply.send(
    ScanBatch(
      files: List.of(batch),
      visited: visited,
      done: true,
      error: failure,
    ),
  );
}
