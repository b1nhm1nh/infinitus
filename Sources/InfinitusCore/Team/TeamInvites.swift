import Foundation
import Crypto

/// The nonces this leader put into invite links (spec §6.2): a request
/// carrying one of them is approved without a tap, once, until the
/// invite's expiry. Team codes (§6.3) carry no nonce and always need
/// Approve. Local to the leader's machine (`<team dir>/invites.json`).
public struct TeamInvites: Codable, Equatable, Sendable {
    /// nonce → expiry (unix seconds)
    public var nonces: [String: Int] = [:]

    public init() {}

    public static func newNonce() -> String {
        Base32.encode(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    /// Mints an invite link (spec §6.2) and remembers its one-time nonce
    /// so this leader's auto-approve recognises the request it comes back
    /// as. The one path from nonce to link: the Mac pane, the CLI and a
    /// LAN invite (spec §6.4) all come through here, so the book and the
    /// link can never disagree about the expiry. Expired nonces are
    /// pruned on the way past — the book is a leader's local file, and
    /// this is the only thing that writes it.
    public static func mint(client: TeamClient, teamDir: URL, days: Int,
                            now: Int = Int(Date().timeIntervalSince1970)) throws -> String {
        let nonce = newNonce()
        var book = load(teamDir: teamDir)
        book.prune(now: now)
        book.add(nonce: nonce, expires: now + days * 86_400)
        try book.save(teamDir: teamDir)
        return try client.code(expiresIn: days * 86_400, nonce: nonce, now: now)
    }

    public mutating func add(nonce: String, expires: Int) { nonces[nonce] = expires }
    public mutating func consume(_ nonce: String) { nonces[nonce] = nil }
    public mutating func prune(now: Int) { nonces = nonces.filter { $0.value > now } }

    /// The stored nonce this request proves it was invited with (unexpired), or nil.
    public func matches(_ request: TeamRequest, now: Int) -> String? {
        guard let proof = request.proof else { return nil }
        return nonces.first { nonce, expires in
            expires > now && TeamRequest.proof(nonce: nonce, kid: request.keys.kid) == proof
        }?.key
    }

    public static func file(teamDir: URL) -> URL { teamDir.appendingPathComponent("invites.json") }

    public static func load(teamDir: URL) -> TeamInvites {
        (try? Data(contentsOf: file(teamDir: teamDir))).flatMap { try? CanonicalJSON.decode(TeamInvites.self, from: $0) } ?? TeamInvites()
    }

    public func save(teamDir: URL) throws {
        try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
        try CanonicalJSON.encode(self).write(to: Self.file(teamDir: teamDir))
    }
}
