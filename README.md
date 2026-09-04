# http_kit

[![CI](https://github.com/zs-dima/http_kit/actions/workflows/ci.yml/badge.svg)](https://github.com/zs-dima/http_kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

A portable HTTP client for Flutter with an onion middleware pipeline. `ApiClient` builds each
request, runs it through the middlewares and the platform engine, and maps the result to a typed
response or exception. The engine is Cronet on Android, NSURLSession on iOS and macOS, the browser
stack on web and `dart:io` elsewhere.

## Features

- One `ApiClient` for JSON, text, bytes, multipart and streamed bodies, with typed exceptions:
  `ApiClientException$Request`, `$Server`, `$Authentication`, `$Network`, `$Timeout`, `$Cancelled`
  and `$Internal`.
- Middlewares for retry with full-jitter backoff and `Retry-After`, connect and receive timeouts,
  bearer authentication and metadata headers. A middleware is a function that wraps the next
  handler, so the order in the list is the order on the wire.
- Cancellation through `CancelToken`, per request and per session: cancelling the session token
  aborts every in-flight request.
- A cap on buffered responses, streaming responses, download progress, and JSON decoding of large
  bodies on a background isolate.
- HTTP/3 on Android from the first request, through QUIC hints for the API host.

## Install

```yaml
dependencies:
  http_kit:
    git:
      url: https://github.com/zs-dima/http_kit.git
      ref: v0.1.0
```

## Usage

```dart
import 'package:http_kit/http_kit.dart';

final api = ApiClient(
  baseUrl: () => Uri.parse('https://api.example.com/v1'),
  middlewares: <ApiClientMiddleware>[
    RetryMiddleware(backoff: const RetryBackoff(maxRetries: 3)).call,
    const TimeoutMiddleware(connectTimeout: Duration(seconds: 10)).call,
    MetadataMiddleware(headers: const {'X-App-Version': '1.0.0'}).call,
  ],
);

final user = await api.get('/users/42').toJson();
await api.post('/users', body: {'name': 'Ada'});
api.close();
```

A request can carry a `context` map for the middlewares: `kNoRetryContextKey`,
`kRetryNonIdempotentContextKey`, `kConnectTimeoutContextKey`, `kReceiveTimeoutContextKey`,
`kMaxResponseSizeContextKey`, `kStreamResponseContextKey` and `kValidateStatusContextKey`.

## Middlewares

| Class | What it does |
|---|---|
| `RetryMiddleware` | Retries idempotent requests on transient failures (network, 5xx, 408, 425, 429) with full-jitter exponential backoff, honoring `Retry-After` and a total time budget. |
| `TimeoutMiddleware` | A connect timeout until the response headers and a receive timeout on idle gaps in the body; both abort the socket. |
| `BearerAuthenticationMiddleware` | Adds `Authorization: Bearer <token>` and calls `logOut` on a missing token, a 401 or a 403. |
| `MetadataMiddleware` | Adds a fixed set of headers to every request. |

## Platforms

| Platform | Engine |
|---|---|
| Android | Cronet (`cronet_http`) with HTTP/2, QUIC and Brotli; `dart:io` when Cronet is unavailable |
| iOS, macOS | NSURLSession (`cupertino_http`) |
| Web | The browser's fetch stack, with credentials on cross-origin requests |
| Windows, Linux | `dart:io` |

Certificate pinning is not wired: the Cronet and NSURLSession adapters expose no pin hook, and
pinning only the `dart:io` fallback would leave the engines mobile actually uses unpinned.

## Credits

Based on code from https://github.com/orgs/DoctorinaAI/repositories.

## Changelog

[CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE)
