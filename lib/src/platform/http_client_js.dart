// ignore_for_file: avoid_web_libraries_in_flutter
// ignore_for_file: avoid-nested-extension-types, the interop types mirror the browser's own nesting.

import 'dart:js_interop';

import 'package:http/browser_client.dart' as browser_client;
import 'package:http/http.dart' as http;
import 'package:http_kit/src/quic_hint.dart';

/// `window.location`.
extension type const _JSLocation._(JSObject _) implements JSObject {
  external String get origin;
}

/// `window`.
extension type const _JSWindow._(JSObject _) implements JSObject {
  external _JSLocation get location;
}

@JS('window')
external _JSWindow get _window;

/// The current window origin, for example `https://example.com`.
String $getOrigin() => _window.location.origin;

/// Creates the browser client. [quicHints] is ignored: the browser controls the HTTP version and
/// compression; the parameter only matches the native factory's signature for the conditional
/// import.
http.Client $createHttpClient({List<QuicHint>? quicHints}) => browser_client.BrowserClient()
  // Cookies on cross-origin requests, for cookie-based authentication.
  ..withCredentials = true;
