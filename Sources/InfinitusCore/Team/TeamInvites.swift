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

    public mutating func add(nonce: String, expires: Int) { nonces[nonce] = expires }
    public mutating func consume(_ nonce: String) { nonces[nonce] = nil }
    public mutating func prune(now: Int) { nonces = nonces.filter { $0.value > now } }

    public func matches(_ request: TeamRequest, now: Int) -> Bool {
        guard let nonce = request.nonce, let expires = nonces[nonce] else { return false }
        return expires > now
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
