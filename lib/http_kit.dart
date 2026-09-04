library http_kit;

// Re-exported so the client API is self-contained and stays free of `dart:ui`.
export 'package:core_model/core_model.dart' show CancelToken, RetryBackoff, RetryNotifier, VoidCallback;

// `ApiClient`, the handler and middleware types, request and response, the exception hierarchy
// and the request context keys.
export 'src/api_client.dart';
// Header names, authorization schemes and content types.
export 'src/headers.dart';
// Retry, timeout, bearer authentication and metadata middlewares.
export 'src/middleware.dart';
// The QUIC hint record shared by `ApiClient` and the platform client factories.
export 'src/quic_hint.dart';
