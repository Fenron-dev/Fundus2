import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/peer_file_cache.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
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
