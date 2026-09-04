// ignore_for_file: avoid_print, an example prints to show the result.

import 'package:http_kit/http_kit.dart';

Future<void> main() async {
  final api = ApiClient(
    baseUrl: () => Uri.parse('https://api.example.com/v1'),
    middlewares: <ApiClientMiddleware>[
      RetryMiddleware(backoff: const RetryBackoff(maxRetries: 3)).call,
      const TimeoutMiddleware(connectTimeout: Duration(seconds: 10)).call,
      MetadataMiddleware(headers: const {'X-App-Version': '1.0.0'}).call,
    ],
  );

  try {
    final user = await api.get('/users/42').toJson();
    print(user['name']);
  } on ApiClientException catch (e) {
    print('${e.code}: ${e.message}');
  } finally {
    api.close();
  }
}
