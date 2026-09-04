// Based on code from https://github.com/orgs/DoctorinaAI/repositories.

import 'dart:async';
import 'dart:collection';
import 'dart:convert' show Converter, JsonEncoder, JsonDecoder, Utf8Decoder, Utf8Encoder, utf8;

import 'package:core_model/core_model.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http_package;
import 'package:http_kit/src/headers.dart';
import 'package:http_kit/src/platform/http_client_vm.dart'
    // ignore: uri_does_not_exist
    if (dart.library.js_interop) 'package:http_kit/src/platform/http_client_js.dart';
import 'package:http_kit/src/quic_hint.dart';

/// The default cap on a buffered response body, 15 MB.
const int _kMaxResponseSize = 15 * 1024 * 1024;

/// Bodies above this size are JSON-decoded on a background isolate through `compute`, so a big
/// payload does not block the frame.
const int kJsonIsolateThreshold = 32 * 1024;

/// The decoder [compute] runs: a top-level function with a sendable argument and result.
Object? _decodeJsonBytes(List<int> bytes) => const Utf8Decoder().fuse<Object?>(const JsonDecoder()).convert(bytes);

/// Sends an [ApiClientRequest] and returns its [ApiClientResponse]. The context map carries
/// per-request data between middlewares.
typedef ApiClientHandler = Future<ApiClientResponse> Function(ApiClientRequest request, Map<String, Object?> context);

/// Wraps an [ApiClientHandler] and returns the wrapped handler.
typedef ApiClientMiddleware = ApiClientHandler Function(ApiClientHandler innerHandler);

/// Builds an [ApiClientMiddleware] from optional callbacks, or merges several into one.
// ignore: avoid-implicitly-nullable-extension-types, prefer-declaring-const-constructor
extension type ApiClientMiddlewareWrapper._(ApiClientMiddleware _fn) {
  /// Creates a new [ApiClientMiddleware] from the given callbacks.
  factory ApiClientMiddlewareWrapper({
    Future<void> Function(ApiClientRequest request, Map<String, Object?> context)? onRequest,
    Future<void> Function(ApiClientResponse response, Map<String, Object?> context)? onResponse,
    Future<void> Function(Object error, StackTrace stackTrace, Map<String, Object?> context)? onError,
  }) => ApiClientMiddlewareWrapper._(
    (innerHandler) => (request, context) async {
      await onRequest?.call(request, context);
      try {
        final response = await innerHandler(request, context);
        await onResponse?.call(response, context);
        return response;
      } on Object catch (error, stackTrace) {
        await onError?.call(error, stackTrace, context);
        rethrow;
      }
    },
  );

  /// Merges the given [middlewares] into a single [ApiClientMiddleware].
  factory ApiClientMiddlewareWrapper.merge(List<ApiClientMiddleware> middlewares) =>
      ApiClientMiddlewareWrapper._(switch (middlewares.length) {
        0 => (handler) => handler,
        1 => middlewares.single,
        _ => (handler) => middlewares.reversed.fold(handler, (handler, middleware) => middleware(handler)),
      });

  /// Applies the wrapped middleware to [innerHandler].
  ApiClientHandler call(ApiClientHandler innerHandler) => _fn(innerHandler);
}

/// Context key under which [ApiClient] exposes the request's effective [CancelToken], so a
/// middleware such as the timeout can abort the socket.
const kCancelTokenContextKey = 'cancelToken';

/// Context flag that opts a request out of having its body re-sent: automatic retries and a retry
/// after a `401` refresh. For bodies that cannot be replayed, such as multipart. A refresh flow may
/// still repair the session; only the replay is skipped.
const kNoRetryContextKey = 'no-retry';

/// Context flag that opts a non-idempotent request (POST, PATCH) into automatic retries. Set it
/// only when the endpoint is safe to repeat, for example under an idempotency key.
const kRetryNonIdempotentContextKey = 'retry-non-idempotent';

/// Context flag (`true`) marking a long-lived server-sent-events request, which is never retried.
/// Set it together with [kStreamResponseContextKey].
const kSseContextKey = 'sse';

/// Per-request override (bytes) for the maximum buffered response size. `0` or negative
/// disables the limit. Falls back to [ApiClient.maxResponseSize] when absent.
const kMaxResponseSizeContextKey = 'max-response-size';

/// Context flag (`true`) that streams the response: the size cap is bypassed and the raw
/// [ApiClientResponse.stream] is returned without buffering, for large downloads.
const kStreamResponseContextKey = 'stream-response';

/// Context value: `void Function(int received, int total)` invoked as the response body is
/// read. `total` is the `Content-Length`, or `-1` when the server did not declare one.
const kOnReceiveProgressContextKey = 'on-receive-progress';

/// Per-request override: `bool Function(int statusCode)` deciding whether a response is a
/// success. Falls back to [ApiClient.validateStatus], then to `statusCode < 400`.
const kValidateStatusContextKey = 'validate-status';

/// An HTTP request with a JSON-encoded body.
extension type const ApiClientRequest(http_package.BaseRequest _request) implements http_package.BaseRequest {
  /// Whether the body is materialized in memory and can be re-sent through [clone]. False for
  /// `MultipartRequest` and `StreamedRequest`, whose bodies are consumed on the first send; a retry
  /// of those would silently strip the body.
  bool get canBeRetried => _request is http_package.Request;

  /// Creates a clone of this request with optional parameter overrides.
  ApiClientRequest clone({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    Uint8List? bodyBytes,
    int? contentLength,
    int? maxRedirects,
  }) {
    final source = _request;
    // The same abortTrigger, so a retried attempt stays abortable.
    final abortTrigger = source is http_package.Abortable ? source.abortTrigger : null;
    final newRequest = abortTrigger == null
        ? http_package.Request(method ?? source.method, url ?? source.url)
        : http_package.AbortableRequest(method ?? source.method, url ?? source.url, abortTrigger: abortTrigger);

    newRequest.headers.addAll(source.headers);
    if (headers != null) {
      newRequest.headers.addAll(headers);
    }

    if (bodyBytes != null) {
      newRequest.bodyBytes = bodyBytes;
    } else if (source is http_package.Request) {
      newRequest.bodyBytes = source.bodyBytes; // a streamed or multipart body cannot be replayed
    }

    newRequest
      ..maxRedirects = maxRedirects ?? source.maxRedirects
      ..followRedirects = source.followRedirects;

    return ApiClientRequest(newRequest);
  }
}

/// A future [ApiClientResponse] with the response accessors lifted onto it.
extension type const FutureApiClientResponse(Future<ApiClientResponse> _future) implements Future<ApiClientResponse> {
  /// The status code.
  Future<int> get statusCode => _future.then((response) => response.statusCode);

  /// The headers.
  Future<Map<String, String>> get headers => _future.then((response) => response.headers);

  /// The body as bytes.
  Future<Uint8List> toBytes() => _future.then((response) => response.toBytes());

  /// The body as a JSON object.
  Future<Map<String, Object?>> toJson() => _future.then((response) => response.toJson());

  /// The body as a JSON list.
  Future<List<Object?>> toJsonList() => _future.then((response) => response.toJsonList());

  /// The body as text.
  Future<String> toText() => _future.then((response) => response.toText());
}

/// An HTTP response.
final class ApiClientResponse {
  static final Converter<List<int>, Object?> _jsonDecoder = const Utf8Decoder().fuse<Object?>(const JsonDecoder());

  /// Creates a response.
  const ApiClientResponse({
    required this.statusCode,
    required this.headers,
    required this.contentLength,
    required this.persistentConnection,
    required this.request,
    required this.stream,
  });

  /// Status code of the response.
  final int statusCode;

  /// The response headers as a hash map.
  final Map<String, String> headers;

  /// The content length of the response body.
  final int contentLength;

  /// Whether the connection should be persistent.
  final bool persistentConnection;

  /// The original request that generated this response.
  final ApiClientRequest request;

  /// The body, as a single-subscription stream: call exactly one of [toBytes], [toJson],
  /// [toJsonList] or [toText] per response; a second read throws "Stream has already been
  /// listened to".
  final http_package.ByteStream stream;

  /// The body as bytes; consumes [stream].
  Future<Uint8List> toBytes() => stream.toBytes();

  /// The body as a JSON object; consumes [stream]. Throws [FormatException] when it is not one.
  Future<Map<String, Object?>> toJson() async {
    final decoded = await _decode(await toBytes());
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw FormatException('Expected JSON object but got ${decoded.runtimeType}');
  }

  /// The body as a JSON list; consumes [stream]. Throws [FormatException] when it is not one.
  Future<List<Object?>> toJsonList() async {
    final decoded = await _decode(await toBytes());
    if (decoded is List<Object?>) return decoded;
    if (decoded is List) return decoded.cast<Object?>();
    throw FormatException('Expected JSON array but got ${decoded.runtimeType}');
  }

  /// The body as text; consumes [stream].
  Future<String> toText() async => utf8.decode(await toBytes());

  /// Creates a clone of this response with optional parameter overrides.
  ApiClientResponse clone({
    int? statusCode,
    Map<String, String>? headers,
    int? contentLength,
    bool? persistentConnection,
    ApiClientRequest? request,
    http_package.ByteStream? stream,
  }) => .new(
    statusCode: statusCode ?? this.statusCode,
    headers: headers ?? Map<String, String>.of(this.headers),
    contentLength: contentLength ?? this.contentLength,
    persistentConnection: persistentConnection ?? this.persistentConnection,
    request: request ?? this.request,
    stream: stream ?? this.stream,
  );

  /// Decodes [bytes] as JSON, on a background isolate above [kJsonIsolateThreshold]; a smaller
  /// body decodes inline, below the cost of spawning an isolate.
  Future<Object?> _decode(List<int> bytes) async => bytes.length > kJsonIsolateThreshold
      ? await compute(_decodeJsonBytes, bytes, debugLabel: 'ApiClient.decodeJson')
      : _jsonDecoder.convert(bytes);
}

/// {@template api_client}
/// An HTTP client that sends requests to a JSON/HTTP API.
/// {@endtemplate}
class ApiClient {
  /// The window origin on web; empty elsewhere.
  static final String origin = $getOrigin();

  ApiClient({
    required this.baseUrl,
    http_package.Client? client,
    this._headers,
    Iterable<ApiClientMiddleware>? middlewares,
    this._maxRedirects = 5,
    this._sessionToken,
    this.maxResponseSize = _kMaxResponseSize,
    this.validateStatus,
  }) : middlewares = List<ApiClientMiddleware>.unmodifiable(middlewares ?? const Iterable.empty()) {
    final http_package.Client internalClient;
    if (client == null) {
      // A QUIC hint for the API host so Cronet attempts HTTP/3 on the first request. `baseUrl` is
      // a lazy resolver and may throw before it is ready; then the hint is omitted.
      Uri? base;
      try {
        base = baseUrl();
      } on Object {
        base = null;
      }
      internalClient = $createHttpClient(quicHints: quicHintsForBaseUrl(base));
    } else {
      internalClient = client;
    }
    // Closed in reverse order on close(); the internal client is closed last.
    _closeCallbacks.add(internalClient.close);
    final pipeline = ApiClientMiddlewareWrapper.merge([...this.middlewares]);
    _handler = _createHandler(internalClient, pipeline.call, maxResponseSize, validateStatus);
  }

  /// The maximum number of redirects to follow.
  final int _maxRedirects;

  /// The pipeline: the middlewares around the internal client.
  late final ApiClientHandler _handler;

  /// Cleanup callbacks, run in reverse order on [close].
  final Queue<VoidCallback> _closeCallbacks = Queue<VoidCallback>();

  /// Headers to include in requests.
  final Map<String, String>? _headers;

  /// The session-scoped [CancelToken], or null. Every request aborts when it is cancelled, so
  /// ending the session tears down all in-flight requests.
  final CancelToken? Function()? _sessionToken;

  /// The base URL for the API.
  final Uri Function() baseUrl;

  /// Immutable list of middlewares to apply for each request.
  final List<ApiClientMiddleware> middlewares;

  /// Default maximum buffered response size in bytes. `0` or negative disables the limit.
  /// Overridable per request via [kMaxResponseSizeContextKey]; bypassed entirely when the
  /// request opts into streaming ([kStreamResponseContextKey]).
  final int maxResponseSize;

  /// Decides whether a response [statusCode] is a success. When it returns `false` the
  /// response is mapped to a typed [ApiClientException]. Defaults to `statusCode < 400`.
  /// Overridable per request via [kValidateStatusContextKey].
  final bool Function(int statusCode)? validateStatus;

  /// QUIC hints for the API host so Cronet attempts HTTP/3 on the first request rather than after
  /// an Alt-Svc upgrade. Null for non-https, hostless or IPv6-literal URLs, since hints target
  /// hostnames; a wrong hint is harmless. Consumed by the platform client factory; ignored on
  /// iOS and web.
  @visibleForTesting
  static List<QuicHint>? quicHintsForBaseUrl(Uri? uri) {
    // `uri.host` strips the brackets of an IPv6 literal, which would make a malformed hint; only
    // IPv6 contains ':'.
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.host.contains(':')) return null;
    final port = uri.hasPort ? uri.port : 443;
    return <QuicHint>[(uri.host, port, port)];
  }

  /// Sends a [method] request to [path].
  ///
  /// [stream] returns the body unbuffered, past the size cap, for large downloads.
  /// [onReceiveProgress] is called as the body is read with `(received, total)`, where `total` is
  /// the Content-Length or `-1` when unknown. [maxResponseSize] overrides the client default.
  FutureApiClientResponse send(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    bool stream = false,
    void Function(int received, int total)? onReceiveProgress,
    int? maxResponseSize,
  }) => _sendUnstreamed(
    method: method,
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: body,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
    stream: stream,
    onReceiveProgress: onReceiveProgress,
    maxResponseSize: maxResponseSize,
  );

  /// Sends a GET request to [path]; [stream], [onReceiveProgress] and [maxResponseSize] as in
  /// [send].
  FutureApiClientResponse get(
    String path, {
    Map<String, String>? headers,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
    bool stream = false,
    void Function(int received, int total)? onReceiveProgress,
    int? maxResponseSize,
  }) => _sendUnstreamed(
    method: 'GET',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: null,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
    stream: stream,
    onReceiveProgress: onReceiveProgress,
    maxResponseSize: maxResponseSize,
  );

  /// Sends a POST request to [path].
  FutureApiClientResponse post(
    String path, {
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => _sendUnstreamed(
    method: 'POST',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: body,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
  );

  /// Sends a multipart/form-data request with any [method], for file uploads.
  ///
  /// [body] values: `String` as a form field; `num` and `bool` as their string form; `List` and
  /// `Map` JSON-encoded; `http_package.MultipartFile` as a file. `Content-Type` and
  /// `Content-Length` are set by the multipart request, so [headers] must not carry them.
  FutureApiClientResponse sendMultipart(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, Object?>? queryParameters,
    Map<String, String>? headers,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) {
    try {
      final uri = _mergePath(baseUrl(), path, queryParameters);
      final ctx = context ?? <String, Object?>{};
      final effectiveToken = cancelToken ?? CancelToken();
      ctx[kCancelTokenContextKey] = effectiveToken;
      // A finalized MultipartRequest cannot be re-sent and clone() cannot rebuild it: no automatic
      // retry, or the retry would go out with an empty body.
      ctx[kNoRetryContextKey] = true;
      final multipartRequest = http_package.AbortableMultipartRequest(
        method.toUpperCase(),
        uri,
        abortTrigger: effectiveToken.whenCancel,
      );

      // Content-Type and Content-Length come from the multipart request itself.
      if (_headers != null || headers != null) {
        final mergedHeaders = {...?_headers, ...?headers};
        for (final MapEntry(:key, :value) in mergedHeaders.entries) {
          final lowerKey = key.toLowerCase();
          if (lowerKey != Headers.contentTypeHeader && lowerKey != Headers.contentLengthHeader) {
            multipartRequest.headers[key] = value;
          }
        }
      }

      if (body != null) {
        for (final MapEntry(:key, :value) in body.entries) {
          if (value == null) continue;

          if (value is http_package.MultipartFile) {
            multipartRequest.files.add(value);
          } else {
            final String stringValue;
            if (value is String) {
              stringValue = value;
            } else if (value is num || value is bool) {
              stringValue = value.toString();
            } else if (value is List || value is Map) {
              stringValue = const JsonEncoder().convert(value);
            } else {
              stringValue = value.toString();
            }
            multipartRequest.fields[key] = stringValue;
          }
        }
      }

      // Link to the session only once the request is built, so a failure above cannot leave a dead
      // token among the session token's children.
      final detachSession = _linkSession(effectiveToken);
      final future = _handler(ApiClientRequest(multipartRequest), ctx);
      future.whenComplete(detachSession).ignore();
      return FutureApiClientResponse(future);
    } on Object catch (e) {
      return FutureApiClientResponse(
        Future<ApiClientResponse>.error(
          ApiClientException$Internal(
            code: 'invalid_request',
            message: 'Failed to create multipart request: $e',
            statusCode: 0,
            error: e,
            data: null,
          ),
        ),
      );
    }
  }

  /// Sends a `POST` multipart/form-data request; see [sendMultipart].
  FutureApiClientResponse postMultipart(
    String path, {
    Map<String, Object?>? body,
    Map<String, Object?>? queryParameters,
    Map<String, String>? headers,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => sendMultipart(
    'POST',
    path,
    body: body,
    queryParameters: queryParameters,
    headers: headers,
    context: context,
    cancelToken: cancelToken,
  );

  /// Sends a `POST` request with a streaming body: chunks from [bodyStream] go to the wire as they
  /// arrive, so a large upload is never buffered whole.
  ///
  /// [contentLength] must match the total size of the stream; it sets `Content-Length`. The body
  /// is consumed once and cannot be replayed, so the request is never retried automatically.
  FutureApiClientResponse postStream(
    String path, {
    required Stream<List<int>> bodyStream,
    required int contentLength,
    Map<String, String>? headers,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) {
    final uri = _mergePath(baseUrl(), path, queryParameters);
    final ctx = context ?? <String, Object?>{};
    final effectiveToken = cancelToken ?? CancelToken();
    ctx[kCancelTokenContextKey] = effectiveToken;
    ctx[kNoRetryContextKey] = true; // a streamed body is consumed on the first send

    final streamedRequest = http_package.AbortableStreamedRequest('POST', uri, abortTrigger: effectiveToken.whenCancel)
      ..contentLength = contentLength;
    if (contentLength > 0) streamedRequest.headers[Headers.contentLengthHeader] = contentLength.toString();
    if (_headers != null) streamedRequest.headers.addAll(_headers);
    if (headers != null) streamedRequest.headers.addAll(headers);

    // Held so it can be cancelled when the request settles: an aborted or timed-out upload must
    // stop draining the source (a file read, an encoder) instead of pumping it into a socket nobody
    // reads.
    final pump = bodyStream.listen(
      streamedRequest.sink.add,
      onError: streamedRequest.sink.addError,
      onDone: streamedRequest.sink.close,
      cancelOnError: true,
    );

    // Link to the session only once the request is built, as the other senders do.
    final detachSession = _linkSession(effectiveToken);
    final future = _handler(ApiClientRequest(streamedRequest), ctx);
    future.whenComplete(() {
      detachSession();
      pump.cancel().ignore(); // a no-op once the stream has completed
    }).ignore();
    return FutureApiClientResponse(future);
  }

  /// Sends a PUT request to [path].
  FutureApiClientResponse put(
    String path, {
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => _sendUnstreamed(
    method: 'PUT',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: body,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
  );

  /// Sends a PATCH request to [path].
  FutureApiClientResponse patch(
    String path, {
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => _sendUnstreamed(
    method: 'PATCH',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: body,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
  );

  /// Sends a DELETE request to [path].
  FutureApiClientResponse delete(
    String path, {
    Map<String, String>? headers,
    Object? body,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => _sendUnstreamed(
    method: 'DELETE',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: body,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
  );

  /// Sends a HEAD request to [path].
  FutureApiClientResponse head(
    String path, {
    Map<String, String>? headers,
    Map<String, Object?>? queryParameters,
    Map<String, Object?>? context,
    CancelToken? cancelToken,
  }) => _sendUnstreamed(
    method: 'HEAD',
    url: _mergePath(baseUrl(), path, queryParameters),
    headers: {...?_headers, ...?headers},
    body: null,
    context: context ?? <String, Object?>{},
    cancelToken: cancelToken,
  );

  /// Clones this client with optional overrides.
  ApiClient clone({
    Uri Function()? url,
    http_package.Client? client,
    Map<String, String>? headers,
    Iterable<ApiClientMiddleware>? middlewares,
    int? maxRedirects,
  }) => .new(
    baseUrl: url ?? baseUrl,
    client: client,
    headers: headers ?? _headers,
    middlewares: middlewares ?? this.middlewares,
    maxRedirects: maxRedirects ?? _maxRedirects,
    // A clone keeps the session binding, the size cap and the status predicate.
    sessionToken: _sessionToken,
    maxResponseSize: maxResponseSize,
    validateStatus: validateStatus,
  );

  /// Closes the client and runs the cleanup callbacks.
  @mustCallSuper
  void close() {
    while (_closeCallbacks.isNotEmpty) {
      final last = _closeCallbacks.removeLast();
      try {
        last();
      } on Object {
        // A failing callback must not stop the others.
      }
    }
  }

  /// Resolves [path] against [base] and merges [queryParameters].
  static Uri _mergePath(
    Uri base,
    String path, [
    Map<String, Object?>? queryParameters,
  ]) {
    final Uri uri;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      // An absolute URL, such as a presigned S3 upload, bypasses the base but still takes
      // [queryParameters].
      uri = Uri.parse(path);
    } else {
      final cleanPath = path.replaceFirst(RegExp('^/+'), '');
      uri = base.replace(path: '${base.path}/$cleanPath');
    }

    if (queryParameters == null || queryParameters.isEmpty) return uri;

    // A collection becomes repeated keys (?id=1&id=2): Uri emits them for an Iterable<String>
    // value. Nulls and null elements are dropped, an empty list drops the key, and the base URL's
    // own query parameters are kept.
    final merged = <String, List<String>>{};
    uri.queryParametersAll.forEach((key, value) => merged[key] = List<String>.of(value));
    for (final MapEntry(:key, :value) in queryParameters.entries) {
      if (value == null) continue;
      if (value is Iterable) {
        final values = <String>[for (final e in value) ?e?.toString()];
        if (values.isEmpty)
          merged.remove(key);
        else
          merged[key] = values;
      } else {
        merged[key] = <String>[value.toString()];
      }
    }

    return merged.isEmpty ? uri : uri.replace(queryParameters: merged);
  }

  /// Links [requestToken] to the session token, if any, so the request is cancelled when the session
  /// ends. Returns the detach callback to run when the request completes, which keeps the session
  /// token's children bounded to in-flight requests.
  VoidCallback _linkSession(CancelToken requestToken) => _sessionToken?.call()?.link(requestToken) ?? () {};

  /// Builds and sends a request with an in-memory body. [context] is the mutable map shared with
  /// the middlewares.
  FutureApiClientResponse _sendUnstreamed({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Object? body,
    required Map<String, Object?> context,
    CancelToken? cancelToken,
    bool stream = false,
    void Function(int received, int total)? onReceiveProgress,
    int? maxResponseSize,
  }) {
    const utf8Encoder = Utf8Encoder();
    // Always abortable: the caller's token or an internal one, exposed through the context so a
    // middleware such as the timeout can tear down the socket. An abortTrigger that never
    // completes behaves like a plain request.
    final effectiveToken = cancelToken ?? CancelToken();
    context[kCancelTokenContextKey] = effectiveToken;
    // Response options for the handler, only when set, so a caller's explicit context entry
    // survives.
    if (stream) context[kStreamResponseContextKey] = true;
    if (onReceiveProgress != null) context[kOnReceiveProgressContextKey] = onReceiveProgress;
    if (maxResponseSize != null) context[kMaxResponseSizeContextKey] = maxResponseSize;
    final request = http_package.AbortableRequest(method, url, abortTrigger: effectiveToken.whenCancel)
      ..maxRedirects = _maxRedirects
      ..followRedirects = _maxRedirects > 0;

    request.headers.addAll(headers);
    // Encode the body by type; Content-Type and Content-Length unless the caller set them.
    switch (body) {
      case null:
        break;

      case final List<int> list:
        final bytes = list is Uint8List ? list : Uint8List.fromList(list);
        request.headers
          ..putIfAbsent(Headers.contentTypeHeader, () => Headers.octetStreamContentType)
          ..putIfAbsent(Headers.contentLengthHeader, () => bytes.length.toString());
        request.bodyBytes = bytes;

      case final String str:
        final bytes = utf8Encoder.convert(str);
        request.headers
          ..putIfAbsent(Headers.contentTypeHeader, () => Headers.textPlainUtf8ContentType)
          ..putIfAbsent(Headers.contentLengthHeader, () => bytes.length.toString());
        request.bodyBytes = bytes;

      case final Map<String, Object?> map:
        const jsonEncoder = kDebugMode ? JsonEncoder.withIndent('  ') : JsonEncoder();
        final bytes = jsonEncoder.fuse(utf8Encoder).convert(map);
        request.headers
          ..putIfAbsent(Headers.contentTypeHeader, () => Headers.jsonUtf8ContentType)
          ..putIfAbsent(Headers.contentLengthHeader, () => bytes.length.toString());
        request.bodyBytes = bytes;

      default:
        throw ArgumentError(
          'Unsupported body type: ${body.runtimeType}. Supported types are: null, List<int>, String, Map<String, Object?>.',
        );
    }
    // Link to the session only once the request is built, so a body-encoding failure above cannot
    // leave a dead token among the session token's children.
    final detachSession = _linkSession(effectiveToken);
    final future = _handler(ApiClientRequest(request), context);
    future.whenComplete(detachSession).ignore();
    return FutureApiClientResponse(future);
  }
}

/// Builds the pipeline: [middleware] around the handler that sends through [internalClient].
///
/// [maxResponseSizeDefault] caps the buffered response size (overridable per request through
/// [kMaxResponseSizeContextKey], bypassed by [kStreamResponseContextKey]). [validateStatusDefault]
/// decides success per status code (overridable through [kValidateStatusContextKey]); when null,
/// `statusCode < 400`.
// ignore: avoid-high-cyclomatic-complexity, one linear response path with its error branches.
ApiClientHandler _createHandler(
  http_package.Client internalClient,
  ApiClientMiddleware middleware,
  int maxResponseSizeDefault,
  bool Function(int statusCode)? validateStatusDefault,
) {
  // Completes [completer] with [error] as an [ApiClientException], unless it already is.
  void throwError(Completer<ApiClientResponse> completer, Object error, StackTrace stackTrace) {
    if (completer.isCompleted)
      return;
    else if (error is ApiClientException)
      completer.completeError(error, stackTrace);
    else
      completer.completeError(
        ApiClientException$Internal(
          code: 'unknown_error',
          message: 'Unknown error.',
          statusCode: 0,
          error: error,
          data: null,
        ),
        stackTrace,
      );
  }

  // The innermost handler: sends the request and maps the result to a response or an exception.
  // ignore: avoid-high-cyclomatic-complexity, one linear response path with its error branches.
  Future<ApiClientResponse> httpHandler(ApiClientRequest request, Map<String, Object?> context) {
    final completer = Completer<ApiClientResponse>();
    // runZonedGuarded routes async errors that escape the inner try/catch through throwError.
    runZonedGuarded<void>(
      () async {
        assert(request.url.scheme.startsWith('http'), 'Invalid URL: ${request.url}');

        final http_package.StreamedResponse streamedResponse;
        try {
          // ignore: avoid-accessing-other-classes-private-members, the extension type is declared here.
          streamedResponse = await internalClient.send(request._request);
        } on http_package.RequestAbortedException catch (error, stackTrace) {
          // Cancelled through a CancelToken: surfaced distinctly so callers and RetryMiddleware can
          // tell it from a failure.
          throwError(
            completer,
            ApiClientException$Cancelled(error: error, data: <String, Object?>{'url': request.url.toString()}),
            stackTrace,
          );
          return;
        } on Object catch (error, stackTrace) {
          throwError(
            completer,
            ApiClientException$Network(
              code: 'network_error',
              message: 'Failed to send request due to a network error.',
              statusCode: 0,
              error: error,
              data: null,
            ),
            stackTrace,
          );
          return;
        }

        // A success passes through to the body; anything else maps to a typed exception. The
        // predicate is the request's ([kValidateStatusContextKey]), then the client's, then
        // `statusCode < 400`.
        final statusCode = streamedResponse.statusCode;
        final isSuccess = switch (context[kValidateStatusContextKey]) {
          final bool Function(int statusCode) predicate => predicate,
          _ => validateStatusDefault ?? _defaultValidateStatus,
        };
        if (!isSuccess(statusCode)) {
          // Capture the error body, bounded, so the server's machine-readable error is not lost:
          // JSON when it parses, raw text otherwise.
          final errorCap = switch (context[kMaxResponseSizeContextKey]) {
            final int m when m > 0 => m,
            _ => maxResponseSizeDefault > 0 ? maxResponseSizeDefault : _kMaxResponseSize,
          };
          final errorBytes = await _readErrorBody(
            streamedResponse,
            errorCap,
          ).timeout(const Duration(seconds: 10), onTimeout: () => null);
          Object? errorBody;
          if (errorBytes != null && errorBytes.isNotEmpty) {
            try {
              errorBody = _decodeJsonBytes(errorBytes);
            } on Object {
              errorBody = utf8.decode(errorBytes, allowMalformed: true);
            }
          }
          throwError(
            completer,
            _statusToException(statusCode, streamedResponse.headers, request.url, errorBody),
            .current,
          );
          return;
        }

        // A streaming request ([kStreamResponseContextKey]) bypasses the size cap and the
        // empty-body heuristic and hands the raw stream to the caller.
        final streaming = context[kStreamResponseContextKey] == true;
        final maxSize = switch (context[kMaxResponseSizeContextKey]) {
          final int m => m,
          _ => maxResponseSizeDefault,
        };
        int contentLength;
        http_package.ByteStream byteStream;
        try {
          contentLength = streamedResponse.contentLength ?? 0;

          // The declared-size cap, unless streaming or the cap is disabled (<= 0).
          if (!streaming && maxSize > 0 && contentLength > maxSize) {
            throwError(
              completer,
              ApiClientException$Internal(
                code: 'response_too_large',
                message: 'Response size ($contentLength bytes) exceeds maximum allowed size ($maxSize bytes).',
                statusCode: statusCode,
                error: null,
                data: <String, Object?>{'contentLength': contentLength, 'maxSize': maxSize},
              ),
              .current,
            );
            return;
          }

          byteStream = !streaming && contentLength <= 0 && streamedResponse.headers[Headers.contentTypeHeader] == null
              ? const http_package.ByteStream(Stream.empty())
              : streamedResponse.stream;

          // Download progress as the body is consumed; `total` is the Content-Length, or -1 when
          // the server did not declare one.
          if (context[kOnReceiveProgressContextKey]
              case final void Function(int received, int total) onReceiveProgress) {
            final total = contentLength > 0 ? contentLength : -1;
            var received = 0;
            byteStream = http_package.ByteStream(
              byteStream.map((chunk) {
                received += chunk.length;
                onReceiveProgress(received, total);
                return chunk;
              }),
            );
          }
        } on Object catch (error, stackTrace) {
          throwError(
            completer,
            ApiClientException$Internal(
              code: 'body_stream_error',
              message: 'Failed to read response stream.',
              statusCode: statusCode,
              error: error,
              data: null,
            ),
            stackTrace,
          );
          return;
        }

        if (!completer.isCompleted) {
          completer.complete(
            ApiClientResponse(
              stream: byteStream,
              statusCode: statusCode,
              headers: streamedResponse.headers,
              contentLength: contentLength,
              persistentConnection: streamedResponse.persistentConnection,
              request: request,
            ),
          );
        }
      },
      (error, stackTrace) {
        throwError(completer, error, stackTrace);
      },
    );

    return completer.future;
  }

  return middleware(httpHandler);
}

/// The default success predicate: any status below 400.
bool _defaultValidateStatus(int statusCode) => statusCode < 400;

/// Reads an error body up to [cap] bytes; null on overflow, abort or a stream error, so capturing
/// the body never masks the status error. An oversized body is skipped, not buffered.
Future<Uint8List?> _readErrorBody(http_package.StreamedResponse response, int cap) async {
  if ((response.contentLength ?? 0) > cap) return null;
  try {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > cap) return null;
    }
    return Uint8List.fromList(bytes);
  } on Object {
    return null;
  }
}

/// Maps a non-success [statusCode] to its typed [ApiClientException], with the per-code `code` and
/// `message`, the captured [errorBody] and `Retry-After` (429, 503).
///
/// Total over every non-success code: 401 and 403 give [ApiClientException$Authentication], 5xx
/// [ApiClientException$Server], everything else [ApiClientException$Request]. A transport failure
/// with no HTTP response is [ApiClientException$Network], raised where the request is sent.
ApiClientException _statusToException(int statusCode, Map<String, String> headers, Uri url, Object? errorBody) {
  final (code, message) = _codeAndMessageFor(statusCode);
  final data = <String, Object?>{
    'url': url.toString(),
    'body': ?errorBody,
    if (statusCode == 429 || statusCode == 503) 'retry-after': ?headers[Headers.retryAfterHeader],
  };
  return switch (statusCode) {
    401 || 403 => ApiClientException$Authentication(code: code, message: message, statusCode: statusCode, data: data),
    >= 500 => ApiClientException$Server(code: code, message: message, statusCode: statusCode, data: data),
    _ => ApiClientException$Request(code: code, message: message, statusCode: statusCode, data: data),
  };
}

/// The `(code, message)` pair for a non-success [statusCode]; an unlisted code gets a generic
/// server or client label.
(String, String) _codeAndMessageFor(int statusCode) => switch (statusCode) {
  509 => ('bandwidth_limit_exceeded', 'Bandwidth limit exceeded (HTTP 509).'),
  503 => (
    'service_unavailable',
    'Service unavailable (HTTP 503). The server is currently unable to handle the request.',
  ),
  501 => ('not_implemented', 'Not implemented (HTTP 501).'),
  500 => ('internal_server_error', 'Internal server error (HTTP 500).'),
  >= 500 => ('server_error', 'Internal server error (HTTP $statusCode).'),
  429 => ('rate_limit', 'Rate limit exceeded (HTTP 429). Too many requests.'),
  422 => ('validation_error', 'Validation error (HTTP 422). Request data is invalid.'),
  413 => ('payload_too_large', 'Payload too large (HTTP 413). The request payload is too large.'),
  412 => ('precondition_failed', 'Precondition failed (HTTP 412). The request failed due to a precondition error.'),
  409 => (
    'conflict',
    'Conflict (HTTP 409). The request could not be completed due to a conflict with the current state of the resource.',
  ),
  404 => ('not_found', 'Resource not found (HTTP 404).'),
  403 => ('forbidden', 'Forbidden access (HTTP 403). Insufficient permissions.'),
  401 => ('unauthorized', 'Unauthorized access (HTTP 401). Authentication required.'),
  400 => ('bad_request', 'Bad request (HTTP 400). The request was malformed or invalid.'),
  _ => ('client_error', 'Client error (HTTP $statusCode).'),
};

/// The base of every error the client raises.
@immutable
abstract class ApiClientException implements Exception {
  const ApiClientException();

  /// The HTTP status code, or 0 when the request produced no response.
  abstract final int statusCode;

  /// A machine-readable code.
  abstract final String code;

  /// A human-readable message.
  abstract final String message;

  /// The underlying error, if any.
  abstract final Object? error;

  /// Extra data: the URL, the captured body, `Retry-After`.
  abstract final Object? data;

  @override
  String toString() => message;
}

/// A fault on this package's side: a response-stream read error, a response-size overflow, a
/// request-construction failure or an unknown error. Not an HTTP 4xx, which is
/// [ApiClientException$Request]. [statusCode] is 0 unless a response was already seen.
final class ApiClientException$Internal extends ApiClientException {
  const ApiClientException$Internal({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// The request never produced an HTTP response: a DNS, TCP, TLS or socket failure; [statusCode] is
/// 0. An HTTP error response is [ApiClientException$Request] or [ApiClientException$Server].
final class ApiClientException$Network extends ApiClientException {
  const ApiClientException$Network({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// The server answered a client-error status other than 401 and 403 (400, 404, 409, 422 and so
/// on). The request is at fault and is not retried; the server's error is the `body` in [data].
final class ApiClientException$Request extends ApiClientException {
  const ApiClientException$Request({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// The server answered a 5xx status. [RetryMiddleware] retries the transient subset.
final class ApiClientException$Server extends ApiClientException {
  const ApiClientException$Server({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// The server answered 401 or 403, or no credentials were available.
final class ApiClientException$Authentication extends ApiClientException {
  const ApiClientException$Authentication({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}

/// The request was aborted through a [CancelToken].
final class ApiClientException$Cancelled extends ApiClientException {
  const ApiClientException$Cancelled({
    this.code = 'cancelled',
    this.message = 'Request was cancelled.',
    this.statusCode = 0,
    this.error,
    this.data,
  });

  @override
  final String code;

  @override
  final String message;

  @override
  final int statusCode;

  @override
  final Object? error;

  @override
  final Object? data;
}
