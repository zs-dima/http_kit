import 'dart:async';

import 'package:core_model/core_model.dart';
import 'package:http/http.dart' as http_package;
import 'package:http_kit/src/api_client.dart';
import 'package:meta/meta.dart';

/// Per-request connect timeout (request to response headers): a [Duration], an `int` of
/// milliseconds or an absolute [DateTime] deadline; zero or past disables it. [kTimeoutContextKey]
/// and [kDurationContextKey] are accepted as aliases.
const kConnectTimeoutContextKey = 'connect-timeout';

/// Per-request receive timeout (the longest idle gap between body chunks): a [Duration] or `int`
/// milliseconds; zero disables it.
const kReceiveTimeoutContextKey = 'receive-timeout';

/// Aliases of [kConnectTimeoutContextKey], same value types.
const kTimeoutContextKey = 'timeout';
const kDurationContextKey = 'duration';

/// {@template timeout_middleware}
/// Bounds a request with two independent timeouts: [connectTimeout], the time to receive the
/// response headers, and [receiveTimeout], the longest idle gap while the body is read (a steady
/// download never trips it, a stalled server does).
///
/// On either timeout the request's [CancelToken] is cancelled, which aborts the socket, and an
/// [ApiClientException$Timeout] (HTTP 408) is thrown.
/// {@endtemplate}
@immutable
class TimeoutMiddleware {
  /// {@macro timeout_middleware}
  const TimeoutMiddleware({
    this.connectTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.duration,
    this.onTimeout,
  });

  /// Time allowed for the response headers. Overridable per request through
  /// [kConnectTimeoutContextKey] or its aliases.
  final Duration connectTimeout;

  /// The longest idle gap allowed between body chunks. Overridable per request through
  /// [kReceiveTimeoutContextKey].
  final Duration receiveTimeout;

  /// Alias of [connectTimeout]; when set it wins.
  final Duration? duration;

  /// Called with the limit that fired.
  final void Function(Duration duration)? onTimeout;

  ApiClientHandler call(ApiClientHandler innerHandler) => (request, context) async {
    final connect = _resolve(
      context[kConnectTimeoutContextKey] ?? context[kTimeoutContextKey] ?? context[kDurationContextKey],
      duration ?? connectTimeout,
    );
    final receive = _resolve(context[kReceiveTimeoutContextKey], receiveTimeout);

    // Connect timeout: request to response headers.
    final ApiClientResponse response;
    final inner = innerHandler(request, context);
    if (connect == null) {
      response = await inner;
    } else {
      try {
        response = await inner.timeout(connect);
      } on TimeoutException catch (e, s) {
        // Abort the socket so it stops consuming bandwidth; `.timeout()` alone only stops awaiting.
        // The caller sees a timeout, not a cancellation.
        if (context[kCancelTokenContextKey] case final CancelToken token) token.cancel(e);
        onTimeout?.call(connect);
        Error.throwWithStackTrace(
          ApiClientException$Timeout(
            duration: connect,
            code: 'timeout',
            statusCode: 408,
            message: 'Request timed out after ${connect.inSeconds} seconds',
            error: e,
          ),
          s,
        );
      }
    }

    // Receive timeout: an idle timer on the body stream. It runs only while the caller consumes the
    // body, after RetryMiddleware has returned, so the two never collide.
    if (receive == null) return response;
    final wrapped = response.stream.timeout(
      receive,
      onTimeout: (sink) {
        if (context[kCancelTokenContextKey] case final CancelToken token) token.cancel();
        onTimeout?.call(receive);
        sink.addError(
          ApiClientException$Timeout(
            duration: receive,
            code: 'receive_timeout',
            statusCode: 408,
            message: 'No data received for ${receive.inSeconds} seconds',
          ),
        );
      },
    );
    return response.clone(stream: http_package.ByteStream(wrapped));
  };

  /// Resolves a context timeout value ([Duration], `int` milliseconds or a [DateTime] deadline) to
  /// a [Duration], or null to disable. An absent or unknown value falls back to [fallback].
  static Duration? _resolve(Object? raw, Duration fallback) => switch (raw) {
    final Duration d when d > .zero => d,
    final int ms when ms > 0 => .new(milliseconds: ms),
    final DateTime d when d.isAfter(DateTime.now()) => d.difference(DateTime.now()).abs(),
    Duration() || int() || DateTime() => null, // an explicit zero or past value disables
    _ => fallback, // absent or unknown: the default
  };
}

/// Thrown when a request exceeds [duration].
final class ApiClientException$Timeout extends ApiClientException implements TimeoutException {
  const ApiClientException$Timeout({
    required this.code,
    required this.message,
    required this.statusCode,
    this.error,
    this.data,
    required this.duration,
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

  /// The limit that was exceeded.
  @override
  final Duration? duration;
}
