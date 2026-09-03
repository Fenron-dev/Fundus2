import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A door on loopback for the media engine.
///
/// The player is mpv, and mpv would have to be taught two things it does not
/// know: a certificate no authority vouches for, and a bearer token. Neither
/// belongs in a media engine. So the token and the pinned certificate stay in
/// Dart, and mpv is handed a plain `http://127.0.0.1:…` address instead.
///
/// The path carries an unguessable capability. Loopback is not private on a
/// shared machine — any process on it can reach this port — so the address
/// being unguessable is what stands between another program and the library.
final class FundusStreamProxy {
  FundusStreamProxy._({
    required HttpServer socket,
    required this.baseUri,
    required this.token,
    required this.libraryId,
    required HttpClient client,
    required String capability,
  }) : _socket = socket,
       _client = client,
       _capability = capability;

  /// The peer these bytes come from.
  final Uri baseUri;
  final String token;
  final String libraryId;

  final HttpServer _socket;
  final HttpClient _client;
  final String _capability;
  StreamSubscription<HttpRequest>? _subscription;

  static Future<FundusStreamProxy> start({
    required Uri baseUri,
    required String token,
    required String libraryId,
    String? certificateFingerprint,
  }) async {
    final socket = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final expected = certificateFingerprint?.trim().toLowerCase();
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: expected == null),
    )..connectionTimeout = const Duration(seconds: 8);
    if (expected != null) {
      client.badCertificateCallback = (certificate, host, port) =>
          sha256.convert(certificate.der).toString() == expected;
    }
    final proxy = FundusStreamProxy._(
      socket: socket,
      baseUri: baseUri,
      token: token,
      libraryId: libraryId,
      client: client,
      capability: _randomValue(24),
    );
    proxy._subscription = socket.listen(proxy._handle);
    return proxy;
  }

  /// Where the engine should open this file.
  ///
  /// The extension is carried over: mpv picks a demuxer by it before it has
  /// read a byte, and a file that arrives as `/3f9a` plays a great deal less
  /// reliably than one that arrives as `/3f9a.mp3`.
  Uri uriFor(String fileId, {String extension = ''}) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _socket.port,
    path: '/$_capability/$fileId$extension',
  );

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _client.close(force: true);
    await _socket.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    if ((request.method != 'GET' && request.method != 'HEAD') ||
        segments.length != 2 ||
        segments.first != _capability) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final fileId = segments.last.split('.').first;
    HttpClientResponse? remote;
    var forwarding = false;
    try {
      // `/files/<id>` describes the file; `/content` is the file.
      final upstream = baseUri.resolve(
        '/v1/libraries/$libraryId/files/$fileId/content',
      );
      final outgoing = await _client.openUrl(request.method, upstream);
      outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      // Seeking is the whole reason this forwards rather than downloads: the
      // engine asks for the stretch it needs, and the answer says which
      // stretch it got.
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) outgoing.headers.set(HttpHeaders.rangeHeader, range);
      remote = await outgoing.close();

      response.statusCode = remote.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = remote.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      forwarding = true;
      if (request.method == 'HEAD') {
        await remote.drain<void>();
        await response.close();
      } else {
        await remote.pipe(response);
      }
    } on Object {
      if (!forwarding) {
        response.statusCode = HttpStatus.badGateway;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': 'remote_stream_unavailable'}));
      }
      try {
        await response.close();
      } on HttpException {
        // The engine may already have hung up on a failed range request.
      }
    }
  }

  static String _randomValue(int count) {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(count, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }
}
