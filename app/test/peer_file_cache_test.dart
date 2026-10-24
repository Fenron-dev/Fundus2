import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/peer_file_cache.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  for (final changed in [false, true]) {
    test(
      'paused transfer ${changed ? 'restarts when ETag changed' : 'resumes with a validated range'}',
      () async {
        final root = await Directory.systemTemp.createTemp('fundus-resume-');
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var version = 1;
        final ranges = <String?>[];
        upstream.listen((request) async {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          ranges.add(range);
          final start = range == null
              ? 0
              : int.parse(range.substring(6).split('-').first);
          request.response.headers.set(HttpHeaders.etagHeader, '"v$version"');
          request.response.statusCode = range == null ? 200 : 206;
          const length = 128 * 1024;
          request.response.contentLength = length - start;
          if (range != null) {
            expect(request.headers.value(HttpHeaders.ifRangeHeader), '"v1"');
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${length - 1}/$length',
            );
          }
          try {
            for (var i = start; i < length; i += 4096) {
              request.response.add(List.filled(4096, version));
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
            await request.response.close();
          } on Object {
            /* Expected when the paused client cancels the body. */
          }
        });
        final proxy = await FundusStreamProxy.start(
          baseUri: Uri.parse('http://localhost:${upstream.port}'),
          token: 'test',
          libraryId: 'library',
        );
        addTearDown(() async {
          await proxy.close();
          await upstream.close(force: true);
          await root.delete(recursive: true);
        });
        final cache = PeerFileCache(proxy: proxy, directory: root);
        const track = LibraryPlaybackTrack(
          fileId: 'file',
          relativePath: '',
          absolutePath: '',
          title: 'book.epub',
          sourceId: 'peer',
          index: 0,
          contentRevision: 'rev',
        );
        var received = 0;
        await expectLater(
          cache.fileFor(
            track,
            mayTransfer: () async => received < 16384,
            onBytes: (bytes, _) => received = bytes,
          ),
          throwsA(isA<TransferPaused>()),
        );
        final partial = File('${root.path}/file.epub.part');
        final offset = await partial.length();
        expect(offset, inInclusiveRange(16384, 131071));
        expect(File('${root.path}/file.epub').existsSync(), isFalse);
        if (changed) version = 2;
        final result = await cache.fileFor(track);
        expect(await File(result).readAsBytes(), everyElement(version));
        expect(await File(result).length(), 128 * 1024);
        expect(
          ranges,
          changed ? [null, 'bytes=$offset-', null] : [null, 'bytes=$offset-'],
        );
        expect(await partial.exists(), isFalse);
      },
    );
  }

  test('concurrent identical fetches share one transfer', () async {
    final root = await Directory.systemTemp.createTemp('fundus-shared-cache-');
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    upstream.listen((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response.contentLength = 4;
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final proxy = await FundusStreamProxy.start(
      baseUri: Uri.parse('http://localhost:${upstream.port}'),
      token: 'test',
      libraryId: 'library',
    );
    addTearDown(() async {
      await proxy.close();
      await upstream.close(force: true);
      await root.delete(recursive: true);
    });
    final cache = PeerFileCache(proxy: proxy, directory: root);
    const track = LibraryPlaybackTrack(
      fileId: 'file',
      relativePath: '',
      absolutePath: '',
      title: 'book.epub',
      sourceId: 'peer',
      index: 0,
    );
    final first = cache.fileFor(track);
    final second = cache.fileFor(track);
    expect(identical(first, second), isTrue);
    expect(await first, await second);
    expect(requests, 1);
    await expectLater(
      cache.fileFor(track, maxBytes: 3),
      throwsA(isA<HttpException>()),
    );
    expect(await File(await first).readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'cache validates without retransferring and remains readable offline',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-file-cache-test-',
      );
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var bodies = 0;
      var requests = 0;
      var denied = false;
      upstream.listen((request) async {
        requests++;
        if (denied) {
          request.response.statusCode = 403;
        } else if (request.headers.value(HttpHeaders.ifNoneMatchHeader) ==
            '"v1"') {
          request.response.statusCode = 304;
        } else {
          bodies++;
          request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final proxy = await FundusStreamProxy.start(
        baseUri: Uri.parse('http://127.0.0.1:${upstream.port}'),
        token: 'test',
        libraryId: 'library',
      );
      try {
        final cache = PeerFileCache(proxy: proxy, directory: root);
        const track = LibraryPlaybackTrack(
          fileId: 'file',
          relativePath: '',
          absolutePath: '',
          title: 'book.epub',
          sourceId: 'peer',
          index: 0,
        );
        final path = await cache.fileFor(track);
        expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
        expect(await cache.fileFor(track), path);
        expect(requests, 2);
        expect(bodies, 1);
        denied = true;
        await expectLater(cache.fileFor(track), throwsA(isA<HttpException>()));
        await upstream.close(force: true);
        expect(await cache.fileFor(track), path);
      } finally {
        await proxy.close();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
