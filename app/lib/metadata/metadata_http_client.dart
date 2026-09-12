import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

/// Only public metadata traffic uses Schannel. Paired servers keep their
/// separate certificate-pinned transport; no global TLS overrides are installed.
http.Client createMetadataHttpClient() =>
    Platform.isWindows ? WindowsMetadataClient() : http.Client();

final class WindowsMetadataException implements Exception {
  WindowsMetadataException(this.host, this.operation, this.code);
  final String host;
  final String operation;
  final int code;

  @override
  String toString() => 'Windows HTTPS: $host, $operation (WinHTTP $code).';
}

/// Buffered transport for small metadata/images, NOT streaming media. Blocking
/// WinHTTP calls run off the UI isolate. Windows validates chains/hostnames and
/// discovers proxies itself, instead of importing CA certificates into Dart.
final class WindowsMetadataClient extends http.BaseClient {
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client is closed');
    final body = await request.finalize().toBytes();
    if (body.length > 2 * 1024 * 1024) {
      throw http.ClientException('Metadata request exceeds 2 MiB');
    }
    final input = _Request(
      request.url.toString(),
      request.method,
      Map.of(request.headers),
      body,
      request.followRedirects,
      request.maxRedirects,
    );
    final result = await Isolate.run(() => _perform(input));
    if (_closed) throw http.ClientException('Client is closed');
    return http.StreamedResponse(
      Stream.value(result.body),
      result.status,
      headers: result.headers,
      request: request,
      isRedirect: result.status >= 300 && result.status < 400,
    );
  }

  @override
  void close() => _closed = true;
}

class _Request {
  _Request(
    this.url,
    this.method,
    this.headers,
    this.body,
    this.follow,
    this.max,
  );
  final String url;
  final String method;
  final Map<String, String> headers;
  final Uint8List body;
  final bool follow;
  final int max;
}

class _Response {
  _Response(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

_Response _perform(_Request input) {
  var uri = Uri.parse(input.url);
  var method = input.method;
  var body = input.body;
  final headers = Map<String, String>.of(input.headers);
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  for (var redirects = 0; ; redirects++) {
    if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
      throw http.ClientException('Unsupported metadata URL');
    }
    final response = _exchange(uri, method, headers, body, deadline);
    final location = response.headers['location'];
    if (!input.follow ||
        location == null ||
        ![301, 302, 303, 307, 308].contains(response.status)) {
      return response;
    }
    if (redirects >= input.max) {
      throw http.ClientException('Too many redirects');
    }
    final next = uri.resolve(location);
    if (uri.scheme == 'https' && next.scheme != 'https') {
      throw http.ClientException('HTTPS downgrade refused');
    }
    if (uri.origin != next.origin) {
      headers.removeWhere(
        (key, _) => [
          'authorization',
          'proxy-authorization',
          'cookie',
          'host',
        ].contains(key.toLowerCase()),
      );
    }
    if ((response.status == 303 && method != 'HEAD') ||
        ([301, 302].contains(response.status) && method == 'POST')) {
      method = 'GET';
      body = Uint8List(0);
      headers.removeWhere(
        (key, _) =>
            ['content-type', 'content-length'].contains(key.toLowerCase()),
      );
    }
    uri = next;
  }
}

// Explicit Win32 ABI, loaded lazily in the worker (never on macOS/Linux).
final _dll = DynamicLibrary.open('winhttp.dll');
final _lastError = DynamicLibrary.open(
  'kernel32.dll',
).lookupFunction<Uint32 Function(), int Function()>('GetLastError');
final _open = _dll
    .lookupFunction<
      Pointer<Void> Function(
        Pointer<Utf16>,
        Uint32,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
      ),
      Pointer<Void> Function(
        Pointer<Utf16>,
        int,
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
      )
    >('WinHttpOpen');
final _connect = _dll
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>, Uint16, Uint32),
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>, int, int)
    >('WinHttpConnect');
final _request = _dll
    .lookupFunction<
      Pointer<Void> Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Pointer<Utf16>>,
        Uint32,
      ),
      Pointer<Void> Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Pointer<Pointer<Utf16>>,
        int,
      )
    >('WinHttpOpenRequest');
final _send = _dll
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Utf16>,
        Uint32,
        Pointer<Void>,
        Uint32,
        Uint32,
        UintPtr,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Utf16>,
        int,
        Pointer<Void>,
        int,
        int,
        int,
      )
    >('WinHttpSendRequest');
final _receive = _dll
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Void>)
    >('WinHttpReceiveResponse');
final _query = _dll
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Uint32,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      ),
      int Function(
        Pointer<Void>,
        int,
        Pointer<Utf16>,
        Pointer<Void>,
        Pointer<Uint32>,
        Pointer<Uint32>,
      )
    >('WinHttpQueryHeaders');
final _read = _dll
    .lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(Pointer<Void>, Pointer<Void>, int, Pointer<Uint32>)
    >('WinHttpReadData');
final _option = _dll
    .lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int, Pointer<Void>, int)
    >('WinHttpSetOption');
final _timeouts = _dll
    .lookupFunction<
      Int32 Function(Pointer<Void>, Int32, Int32, Int32, Int32),
      int Function(Pointer<Void>, int, int, int, int)
    >('WinHttpSetTimeouts');
final _close = _dll
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'WinHttpCloseHandle',
    );

_Response _exchange(
  Uri uri,
  String method,
  Map<String, String> headers,
  Uint8List body,
  DateTime deadline,
) => using((arena) {
  Pointer<Void> session = nullptr, connection = nullptr, request = nullptr;
  void check(int result, String operation) {
    if (result == 0) {
      throw WindowsMetadataException(uri.host, operation, _lastError());
    }
  }

  void option(Pointer<Void> handle, int key, int value) {
    final data = arena<Uint32>()..value = value;
    check(_option(handle, key, data.cast(), sizeOf<Uint32>()), 'option $key');
  }

  void checkDeadline() {
    if (DateTime.now().isAfter(deadline)) {
      throw WindowsMetadataException(uri.host, 'deadline', 12002);
    }
  }

  try {
    checkDeadline();
    session = _open(
      'Fundus/2'.toNativeUtf16(allocator: arena),
      4,
      nullptr,
      nullptr,
      0,
    );
    if (session == nullptr) check(0, 'open');
    check(_timeouts(session, 8000, 8000, 8000, 8000), 'timeouts');
    // TLS 1.2 everywhere supported by Fundus; TLS 1.3 on newer Windows.
    final protocols = arena<Uint32>()..value = 0x2800;
    if (_option(session, 84, protocols.cast(), 4) == 0) {
      option(session, 84, 0x800);
    }
    connection = _connect(
      session,
      uri.host.toNativeUtf16(allocator: arena),
      uri.port,
      0,
    );
    if (connection == nullptr) check(0, 'connect');
    final target =
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    request = _request(
      connection,
      method.toNativeUtf16(allocator: arena),
      target.toNativeUtf16(allocator: arena),
      nullptr,
      nullptr,
      nullptr,
      uri.scheme == 'https' ? 0x00800000 : 0,
    );
    if (request == nullptr) check(0, 'request');
    option(request, 88, 0); // Redirects handled above; never leak credentials.
    option(request, 77, 2); // Never send ambient Windows logon credentials.
    option(request, 118, 3); // Native gzip/deflate decompression.
    final lines = <String>[];
    for (final entry in headers.entries) {
      if (RegExp(r'[\r\n]').hasMatch('${entry.key}${entry.value}')) {
        throw http.ClientException('Invalid HTTP header');
      }
      if (![
        'content-length',
        'accept-encoding',
        'host',
      ].contains(entry.key.toLowerCase())) {
        lines.add('${entry.key}: ${entry.value}\r\n');
      }
    }
    final headerText = lines.join();
    final data = arena<Uint8>(body.isEmpty ? 1 : body.length);
    data.asTypedList(body.length).setAll(0, body);
    check(
      _send(
        request,
        headerText.toNativeUtf16(allocator: arena),
        headerText.length,
        data.cast(),
        body.length,
        body.length,
        0,
      ),
      'send',
    );
    check(_receive(request, nullptr), 'receive');
    final length = arena<Uint32>()..value = 4;
    final status = arena<Uint32>();
    check(
      _query(request, 19 | 0x20000000, nullptr, status.cast(), length, nullptr),
      'status',
    );
    length.value = 0;
    final probe = _query(request, 22, nullptr, nullptr, length, nullptr);
    if (probe == 0 && _lastError() != 122) check(0, 'headers size');
    if (length.value > 65536) {
      throw http.ClientException('Metadata headers too large');
    }
    final raw = arena<Uint8>(length.value + 2);
    check(_query(request, 22, nullptr, raw.cast(), length, nullptr), 'headers');
    final responseHeaders = <String, String>{};
    for (final line in raw.cast<Utf16>().toDartString().split('\r\n').skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      responseHeaders.update(
        key,
        (old) => '$old, $value',
        ifAbsent: () => value,
      );
    }
    final bytes = BytesBuilder(copy: false);
    final buffer = arena<Uint8>(65536);
    final count = arena<Uint32>();
    while (true) {
      checkDeadline();
      check(_read(request, buffer.cast(), 65536, count), 'read');
      if (count.value == 0) break;
      if (bytes.length + count.value > 32 * 1024 * 1024) {
        throw http.ClientException('Metadata response exceeds 32 MiB');
      }
      bytes.add(Uint8List.fromList(buffer.asTypedList(count.value)));
    }
    // WinHTTP already decoded compressed bodies.
    responseHeaders.remove('content-encoding');
    responseHeaders['content-length'] = '${bytes.length}';
    return _Response(status.value, responseHeaders, bytes.takeBytes());
  } finally {
    if (request != nullptr) _close(request);
    if (connection != nullptr) _close(connection);
    if (session != nullptr) _close(session);
  }
});
