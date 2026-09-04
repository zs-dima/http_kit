import 'package:flutter_test/flutter_test.dart';
import 'package:http_kit/http_kit.dart';

void main() {
  group('ApiClient.quicHintsForBaseUrl', () {
    test('an https host gives one hint on the default port 443', () {
      expect(
        ApiClient.quicHintsForBaseUrl(Uri.parse('https://api.example.com/v1')),
        equals(<QuicHint>[('api.example.com', 443, 443)]),
      );
    });

    test('explicit https port is preserved', () {
      expect(
        ApiClient.quicHintsForBaseUrl(Uri.parse('https://api.example.com:8443')),
        equals(<QuicHint>[('api.example.com', 8443, 8443)]),
      );
    });

    test('a non-https scheme gives null, since QUIC implies TLS', () {
      expect(ApiClient.quicHintsForBaseUrl(Uri.parse('http://api.example.com')), isNull);
    });

    test('a null uri gives null', () {
      expect(ApiClient.quicHintsForBaseUrl(null), isNull);
    });

    test('a hostless uri gives null', () {
      expect(ApiClient.quicHintsForBaseUrl(Uri.parse('https:///path')), isNull);
    });

    test('an IPv6 literal host gives null: hints target hostnames and Uri.host drops the brackets', () {
      expect(ApiClient.quicHintsForBaseUrl(Uri.parse('https://[2001:db8::1]:8443/v1')), isNull);
    });

    test('an IPv4 literal host is kept', () {
      expect(
        ApiClient.quicHintsForBaseUrl(Uri.parse('https://10.0.0.1/v1')),
        equals(<QuicHint>[('10.0.0.1', 443, 443)]),
      );
    });

    test('the scheme is matched case-insensitively', () {
      expect(
        ApiClient.quicHintsForBaseUrl(Uri.parse('HTTPS://api.example.com')),
        equals(<QuicHint>[('api.example.com', 443, 443)]),
      );
    });
  });
}
