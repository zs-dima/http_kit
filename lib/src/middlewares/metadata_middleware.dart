import 'package:http_kit/src/api_client.dart';
import 'package:meta/meta.dart';

/// {@template metadata_middleware}
/// Adds a fixed set of headers to every request.
///
/// It takes a ready map and merges it into each request; composing the map (application metadata,
/// an environment header) is the caller's job at wiring time.
///
/// First-party only: never attach it to a client that talks to third-party hosts, such as S3
/// presigned uploads, so internal metadata does not leak off-origin.
/// {@endtemplate}
@immutable
class MetadataMiddleware {
  /// {@macro metadata_middleware}
  MetadataMiddleware({required Map<String, String> headers}) : _headers = Map<String, String>.unmodifiable(headers);

  final Map<String, String> _headers;

  ApiClientHandler call(ApiClientHandler innerHandler) =>
      (request, context) => innerHandler(request..headers.addAll(_headers), context);
}
