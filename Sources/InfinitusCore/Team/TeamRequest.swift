import Foundation

/// `requests/<kid>.json` (spec §6.2/6.3): a joiner's keys and name,
/// stored as `Signed<TeamRequest>` by the joiner. `nonce` echoes the
/// invite it came from so the leader's app can auto-approve its own
/// invites (plan 6); nil for team-code requests.
public struct TeamRequest: Codable, Equatable, Sendable {
    public var keys: TeamKeys
    public var name: String
    public var devices: [String]
    public var platform: String
    public var at: Int
    public var nonce: String?

    public init(keys: TeamKeys, name: String, devices: [String], platform: String, at: Int, nonce: String? = nil) {
        self.keys = keys; self.name = name; self.devices = devices
        self.platform = platform; self.at = at; self.nonce = nonce
    }
}
