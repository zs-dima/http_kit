// VoidCallback from core_model keeps this file free of dart:ui.
import 'package:core_model/core_model.dart' show VoidCallback;
import 'package:http_kit/src/api_client.dart';
import 'package:http_kit/src/headers.dart';
import 'package:meta/meta.dart';

/// {@template bearer_authentication_middleware}
/// Attaches `Authorization: Bearer <token>` to every request and logs out when the token is missing
/// or the server replies `401` or `403`. It refreshes nothing and exempts no path; a refresh flow
/// belongs in a middleware layered above it.
///
/// Named after the Bearer scheme it implements (RFC 6750), not HTTP Basic.
/// {@endtemplate}
@immutable
class BearerAuthenticationMiddleware {
  /// {@macro bearer_authentication_middleware}
  const BearerAuthenticationMiddleware({required this.getToken, required this.logOut});

  /// Resolves the current bearer token, without the scheme. A null or empty result means "not
  /// authenticated": [logOut] runs and an [ApiClientException$Authentication] is thrown.
  final Future<String?> Function() getToken;

  /// Runs when the token is missing or fails to resolve, and when the server replies `401` or `403`.
  final VoidCallback logOut;

  ApiClientHandler call(ApiClientHandler innerHandler) => (request, context) async {
    try {
      final token = await getToken();
      if (token == null || token.isEmpty) {
        throw const ApiClientException$Authentication(
          code: 'no_credentials',
          message: 'No authentication token available.',
          statusCode: 0,
        );
      }
      request.headers[Headers.authorizationHeader] = '${Headers.bearerScheme} $token';
    } on Object {
      // A missing token or a resolution failure: log out and surface the error.
      logOut();
      rethrow;
    }

    try {
      return await innerHandler(request, context);
    } on ApiClientException catch (e) {
      const logoutStatusCodes = <int>{401, 403};
      if (logoutStatusCodes.contains(e.statusCode)) logOut();
      rethrow;
    }
  };
}
