import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The pairing rendezvous on infinitus.run (#9 remote access, user
/// 2026-09-03 "can the domain be reused for other users?" → yes, this
/// way): a Mac on the free quick tunnel gets a fresh *.trycloudflare.com
/// URL every start, so it PUTs the current one under a key only it and
/// its paired phones can derive — SHA-256 of the pairing token — and a
/// phone whose saved tunnel URL stopped answering GETs the new one. The
/// URL alone opens nothing (every mirror request still carries the
/// bearer token) and the key is unguessable, so the service holds no
/// accounts. site/src/worker.js is the other half.
public enum MirrorRendezvous {
    public static let defaultBase = "https://infinitus.run/rendezvous"

    /// Lower-case hex SHA-256 of the normalized token — nil where there's
    /// no CryptoKit (the Linux tray runs no quick tunnel, so never needs it).
    public static func key(token: String) -> String? {
        let normalized = MirrorPairing.normalize(token)
        guard !normalized.isEmpty else { return nil }
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    public static func url(token: String, base: String = defaultBase) -> URL? {
        guard let key = key(token: token) else { return nil }
        return URL(string: "\(base)/\(key)")
    }

    /// The only endpoints the rendezvous replaces: quick-tunnel URLs.
    public static func isEphemeral(_ endpoint: String) -> Bool {
        endpoint.lowercased().contains(".trycloudflare.com")
    }

    /// The Mac's side: `{"url": …}` for the PUT.
    public static func publishBody(url: String) -> Data {
        (try? JSONEncoder().encode(["url": url])) ?? Data()
    }

    /// The phone's side: the URL a GET answered with, if any.
    public static func parseLookup(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String, isEphemeral(url) else { return nil }
        return url
    }
}
