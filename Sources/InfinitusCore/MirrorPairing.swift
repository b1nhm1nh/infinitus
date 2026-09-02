import Foundation

// MARK: - Backend-free remote access (#9)
//
// The phone reaches the Mac with no server in between: same-LAN, over a
// tailnet, or through a throwaway Cloudflare quick tunnel. All three are
// the same listener on the same port — what makes them safe to expose is
// the pairing token every request must carry (MirrorTransport.isAuthorized).
//
// Everything here is pure Foundation so the Linux tray still compiles:
// the QR rendering (CoreImage), the interface walk (getifaddrs) and the
// cloudflared child process live on the mac side.

public enum MirrorPairing {
    /// RFC 4648 base32: uppercase letters and 2–7, so a token read off a
    /// screen has no 0/O or 1/l to get wrong, and it survives a URL query
    /// and a QR's alphanumeric mode untouched.
    public static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    public static let tokenLength = 24
    /// The URL scheme the phone registers for QR / deep-link pairing.
    public static let urlScheme = "infinitus"
    public static let pairHost = "pair"

    // MARK: - The token

    public static func generateToken(length: Int = tokenLength) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Uppercases and drops everything that isn't in the alphabet, so a
    /// token pasted with spaces, dashes or a stray newline still matches.
    public static func normalize(_ text: String) -> String {
        let allowed = Set(alphabet)
        return String(text.uppercased().filter(allowed.contains))
    }

    /// Length-independent compare over the whole token — no early exit on
    /// the first differing character.
    public static func matches(_ presented: String, _ expected: String) -> Bool {
        let a = Array(presented.utf8), b = Array(expected.utf8)
        var diff = a.count ^ b.count
        for i in 0..<max(a.count, b.count) {
            diff |= Int(i < a.count ? a[i] : 0) ^ Int(i < b.count ? b[i] : 0)
        }
        return diff == 0
    }

    /// What the settings pane shows until "Reveal" is pressed.
    public static func mask(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "•", count: token.count) }
        return String(token.prefix(4)) + String(repeating: "•", count: token.count - 8)
            + String(token.suffix(4))
    }

    // MARK: - Pair URLs (what a QR encodes)

    /// `infinitus://pair?url=http://192.168.1.20:47824&token=ABC…`
    public static func pairURL(endpoint: String, token: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let escaped = endpoint.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? endpoint
        return "\(urlScheme)://\(pairHost)?url=\(escaped)&token=\(normalize(token))"
    }

    public struct Pairing: Sendable, Equatable {
        /// The endpoint text, exactly as it should land in the phone's
        /// address field (MirrorTransport.parseEndpoint understands it).
        public let endpoint: String
        public let token: String

        public init(endpoint: String, token: String) {
            self.endpoint = endpoint
            self.token = token
        }
    }

    /// Reads a scanned or deep-linked pair URL. Tolerates the token
    /// riding as `t=` (the same name the HTTP query uses) and a missing
    /// endpoint (then the phone keeps whatever it had and only re-pairs).
    public static func parsePairURL(_ text: String) -> Pairing? {
        guard let components = URLComponents(
            string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard components.scheme?.lowercased() == urlScheme else { return nil }
        // `infinitus://pair?…` puts "pair" in host; `infinitus:pair?…` in path.
        let where_ = components.host ?? components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        guard where_.lowercased() == pairHost else { return nil }
        let items = components.queryItems ?? []
        let token = normalize(items.first { $0.name == "token" || $0.name == "t" }?
            .value ?? "")
        guard !token.isEmpty else { return nil }
        let endpoint = (items.first { $0.name == "url" || $0.name == "endpoint" }?
            .value ?? "").trimmingCharacters(in: .whitespaces)
        return Pairing(endpoint: endpoint, token: token)
    }

    // MARK: - Which addresses to offer

    /// A tailnet address, if this machine is on one: Tailscale hands out
    /// 100.64.0.0/10 (CGNAT) addresses on a utun, and the mirror listener
    /// already binds every interface — so being on the tailnet IS the
    /// "anywhere" mode, no extra plumbing.
    public static func tailnetAddress(in addresses: [String]) -> String? {
        addresses.first { address in
            guard let octets = ipv4Octets(address) else { return false }
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
    }

    /// The LAN address to put on the first QR: a real private IPv4, not
    /// loopback, not link-local, and not the tailnet one.
    public static func lanAddress(in addresses: [String]) -> String? {
        addresses.first { address in
            guard let octets = ipv4Octets(address) else { return false }
            if octets[0] == 127 || octets[0] == 0 { return false }
            if octets[0] == 169 && octets[1] == 254 { return false }
            if octets[0] == 100 && (64...127).contains(octets[1]) { return false }
            return true
        }
    }

    static func ipv4Octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }

    // MARK: - Cloudflare quick tunnel

    /// cloudflared announces the throwaway hostname on stderr, boxed in
    /// ASCII art: pull the first `https://….trycloudflare.com` out of a
    /// line, whatever decoration surrounds it.
    public static func quickTunnelURL(in line: String) -> String? {
        guard let start = line.range(of: "https://") else { return nil }
        let rest = line[start.lowerBound...]
        let stops = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "|\"'<>)]},"))
        let url = String(rest.unicodeScalars.prefix { !stops.contains($0) })
        return url.hasSuffix(".trycloudflare.com") ? url : nil
    }
}
