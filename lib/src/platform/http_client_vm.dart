import 'dart:io' show Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;
import 'package:http_kit/src/quic_hint.dart';

/// The window origin on web; the VM has none, so an empty string.
String $getOrigin() => '';

/// Creates the HTTP client for the platform: Cronet on Android, NSURLSession on iOS and macOS,
/// `dart:io` everywhere else and whenever the native engine fails to start.
///
/// The Cronet engine is built with HTTP/2, QUIC and Brotli enabled; the default engine has QUIC and
/// Brotli off. [quicHints] pre-seeds hosts known to speak HTTP/3 so the first request already
/// attempts QUIC, and a wrong hint is harmless. `closeEngine: true` ties the engine's lifetime to
/// the client. NSURLSession negotiates HTTP/2, HTTP/3 and compression itself, so [quicHints] does
/// not apply there, nor to the `dart:io` client.
///
/// Every client honors `package:http` request abortion, so cancellation and timeout teardown behave
/// the same on every platform.
///
/// Not configured: the on-disk cache with QUIC 0-RTT, which would make this factory asynchronous
/// for little gain on a mostly uncacheable API, and certificate pinning. `cronet_http` 1.9 exposes
/// no pin configuration and `cupertino_http` 3.0 no server-trust hook, so pinning is possible only
/// on the `dart:io` fallback, which is not the client mobile runs; wiring it there would leave the
/// native engines unpinned while looking secure.
http.Client $createHttpClient({List<QuicHint>? quicHints}) {
  try {
    if (Platform.isAndroid) {
      return CronetClient.fromCronetEngine(
        CronetEngine.build(enableHttp2: true, enableQuic: true, enableBrotli: true, quicHints: quicHints),
        closeEngine: true,
      );
    }
    if (Platform.isIOS || Platform.isMacOS) return CupertinoClient.defaultSessionConfiguration();
  } on Object {
    // The native engine is unavailable: fall through to the dart:io client.
  }
  return io_client.IOClient();
}
