/// A host known to speak HTTP/3, so the first request already attempts QUIC. Without a hint QUIC is
/// opportunistic and starts only after the server advertises it through Alt-Svc on an earlier
/// response.
///
/// The record shape `CronetEngine.build(quicHints:)` takes. A wrong or stale hint is harmless:
/// Cronet falls back to HTTP/2 or HTTP/1.1. Ignored on iOS, macOS and web, where the platform stack
/// picks the protocol itself.
typedef QuicHint = (String host, int port, int alternativePort);
