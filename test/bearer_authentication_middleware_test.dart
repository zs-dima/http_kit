import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_kit/http_kit.dart';

/// [BearerAuthenticationMiddleware] driven through [ApiClient] over a [MockClient].
void main() {
  ApiClient apiWith(
    MockClient client, {
    required Future<String?> Function() getToken,
    required VoidCallback logOut,
  }) => .new(
    baseUrl: () => Uri.parse('https://api.test'),
    client: client,
    middlewares: <ApiClientMiddleware>[
      BearerAuthenticationMiddleware(getToken: getToken, logOut: logOut).call,
    ],
  );

  group('BearerAuthenticationMiddleware', () {
    test('attaches "Authorization: Bearer <token>" from getToken on success', () async {
      var logOutCount = 0;
      Map<String, String>? seen;
      final api = apiWith(
        MockClient((request) async {
          seen = Map<String, String>.of(request.headers);
          return http.Response('ok', 200);
        }),
        getToken: () async => 'tok-123',
        logOut: () => logOutCount++,
      );

      await api.get('/data');

      expect(seen?['authorization'], equals('Bearer tok-123'));
      expect(logOutCount, isZero);
    });

    test('logs out and fails fast when the token is null, sending no request', () async {
      var logOutCount = 0;
      var requestSent = false;
      final api = apiWith(
        MockClient((_) async {
          requestSent = true;
          return http.Response('ok', 200);
        }),
        getToken: () async => null,
        logOut: () => logOutCount++,
      );

      await expectLater(api.get('/data'), throwsA(isA<ApiClientException>()));
      expect(logOutCount, equals(1));
      expect(requestSent, isFalse);
    });

    test('logs out when the token is empty', () async {
      var logOutCount = 0;
      final api = apiWith(
        MockClient((_) async => http.Response('ok', 200)),
        getToken: () async => '',
        logOut: () => logOutCount++,
      );

      await expectLater(api.get('/data'), throwsA(isA<ApiClientException>()));
      expect(logOutCount, equals(1));
    });

    test('logs out when the server replies 401', () async {
      var logOutCount = 0;
      final api = apiWith(
        MockClient((_) async => http.Response('unauthorized', 401)),
        getToken: () async => 'tok',
        logOut: () => logOutCount++,
      );

      await expectLater(api.get('/data'), throwsA(isA<ApiClientException>()));
      expect(logOutCount, equals(1));
    });

    test('logs out when the server replies 403', () async {
      var logOutCount = 0;
      final api = apiWith(
        MockClient((_) async => http.Response('forbidden', 403)),
        getToken: () async => 'tok',
        logOut: () => logOutCount++,
      );

      await expectLater(api.get('/data'), throwsA(isA<ApiClientException>()));
      expect(logOutCount, equals(1));
    });

    test('does not log out on a 500; only 401 and 403 do', () async {
      var logOutCount = 0;
      final api = apiWith(
        MockClient((_) async => http.Response('boom', 500)),
        getToken: () async => 'tok',
        logOut: () => logOutCount++,
      );

      await expectLater(api.get('/data'), throwsA(isA<ApiClientException>()));
      expect(logOutCount, isZero);
    });
  });
}
