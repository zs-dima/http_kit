// ignore_for_file: prefer-async-callback
import 'dart:math' as math;

import 'package:core_model/core_model.dart';
import 'package:http_kit/src/api_client.dart';
import 'package:http_kit/src/middlewares/timeout_middleware.dart';
import 'package:meta/meta.dart';

/// HTTP methods that are safe to retry automatically (RFC 9110 §9.2.2).
const _kIdempotentMethods = <String>{'GET', 'HEAD', 'PUT', 'DELETE', 'OPTIONS', 'TRACE'};

/// Cap on a server-provided `Retry-After`. The server is authoritative; the total
/// [RetryBackoff.maxElapsed] budget is the real ceiling.
const _kMaxRetryAfter = Duration(seconds: 60);

/// Parses a delta-seconds `Retry-After` from a 429 (`$Request`) or 503 (`$Server`)
/// [ApiClientException], capped at [_kMaxRetryAfter]. Null when absent or not delta-seconds.
///
/// The HTTP-date form (RFC 9110 §10.2.3) is not parsed: it is rare, and the fallback to bounded
/// full-jitter backoff is safe; parsing it would add a date dependency for a near-unused path.
Duration? _retryAfter(Object error) {
  if (error is! ApiClientException) return null;
  if (error.data case <String, Object?>{'retry-after': final String ra}) {
    final seconds = int.tryParse(ra.trim());
    if (seconds != null && seconds >= 0) {
      final d = Duration(seconds: seconds);
      return d > _kMaxRetryAfter ? _kMaxRetryAfter : d;
    }
  }
  return null;
}

/// {@template retry_middleware}
/// The one transient-retry layer for HTTP: retries idempotent requests with full-jitter exponential
/// backoff ([RetryBackoff]), honoring `Retry-After` and a total time budget. Retries elsewhere
/// (repositories, use cases) nest and amplify; do not add them.
///
/// Error classification is one policy, [retryEvaluator] or [defaultRetryEvaluator]. Retries gate
/// on method idempotency (RFC 9110) and never cover `$Timeout`, whose abort token is already
/// consumed.
/// {@endtemplate}
@immutable
class RetryMiddleware {
  /// {@macro retry_middleware}
  RetryMiddleware({this.backoff = const RetryBackoff(), this.retryEvaluator, this.onRetry, math.Random? random})
    : _random = random ?? math.Random();

  /// Jitter source; injectable for deterministic tests.
  final math.Random _random;

  /// Backoff policy: max retries, full-jitter exponential delays, per-attempt ceiling, total budget.
  final RetryBackoff backoff;

  /// Overrides [defaultRetryEvaluator] for deciding whether an error is retryable.
  final bool Function(Object error, int attempt)? retryEvaluator;

  /// Called once per retry, just before the backoff sleep. Retries are otherwise invisible: a
  /// logging middleware outside this one sees only the last attempt.
  final RetryNotifier? onRetry;

  /// Whether [error] is worth retrying: transient failures only. Used when [retryEvaluator] is
  /// absent; a custom evaluator replaces it entirely.
  ///
  /// `$Cancelled` and `$Timeout` are refused in [call] regardless, because their abort token is
  /// already completed and a retry would abort at once; they are listed here so the evaluator is
  /// correct on its own.
  static bool defaultRetryEvaluator(Object error, int attempt) => switch (error) {
    ApiClientException$Authentication() => false, // a 401 belongs to the authentication layer
    ApiClientException$Cancelled() || ApiClientException$Timeout() => false,
    // Transient failures only, by status code across every subtype ($Network 0, $Server 5xx,
    // $Request 408/425/429); never a non-transient 4xx.
    ApiClientException(:final statusCode) => const <int>{
      0,
      408,
      425,
      429,
      500,
      502,
      503,
      504,
      509,
    }.contains(statusCode),
    _ => false, // unknown errors are not retried
  };

  ApiClientHandler call(ApiClientHandler innerHandler) => (request, context) async {
    // Only idempotent methods retry automatically: repeating a POST or PATCH whose response was
    // lost could duplicate a side effect. Endpoints with an idempotency key opt in through the
    // context.
    final idempotent =
        _kIdempotentMethods.contains(request.method.toUpperCase()) || context[kRetryNonIdempotentContextKey] == true;

    final shouldNotRetry =
        context[kNoRetryContextKey] == true ||
        context[kSseContextKey] == true ||
        backoff.maxRetries < 1 ||
        !idempotent ||
        !request.canBeRetried; // multipart and streamed bodies cannot be replayed by clone()
    if (shouldNotRetry) return innerHandler(request, context);
    final evaluate = retryEvaluator ?? defaultRetryEvaluator;
    var attempt = 0;
    var clonedRequest = request;
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        return await innerHandler(clonedRequest, context);
      } catch (e) {
        // A cancelled or timed-out request has completed its abort token; a retry would abort at
        // once.
        final mechanicForbidsRetry = e is ApiClientException$Cancelled || e is ApiClientException$Timeout;
        if (mechanicForbidsRetry || attempt >= backoff.maxRetries || !evaluate(e, attempt)) {
          rethrow;
        }
        // The server's Retry-After (429, 503) verbatim; otherwise full-jitter backoff.
        final delay = _retryAfter(e) ?? backoff.backoff(attempt, _random);
        // Give up rather than wait past the total budget.
        if (!backoff.withinBudget(stopwatch.elapsed, delay)) rethrow;
        onRetry?.call(e, attempt, delay);
        await Future<void>.delayed(delay);
        attempt++;
        clonedRequest = clonedRequest.clone();
      }
    }
  };
}
