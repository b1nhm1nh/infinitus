import Foundation
import InfinitusCore

/// The Mac app's `TeamSecrets` (spec §2.1): identity secret + store
/// tokens in the login keychain under `Keychain.teamService`. Reads skip
/// the access-prompt UI (a dev build's ACL prompt must never block the
/// app): no grant = no identity = "pending" until the user re-signs in.
struct KeychainTeamSecrets: TeamSecrets, Sendable {
    enum SecretsError: Error { case writeFailed }

    func read(_ name: String) -> Data? { Keychain.readData(account: name, service: Keychain.teamService) }

    func write(_ name: String, _ data: Data) throws {
        guard Keychain.writeData(account: name, value: data, service: Keychain.teamService) else { throw SecretsError.writeFailed }
    }

    func delete(_ name: String) { Keychain.delete(account: name, service: Keychain.teamService) }
}

/// Which secrets store an instance uses: files when `INFINITUS_TEAM_DIR`
/// redirects the team dir (the e2e gate, a second dev instance — CI has
/// no keychain to answer), the keychain otherwise. Returned as a factory
/// so background work builds its own value and captures nothing shared.
enum TeamSecretsFactory {
    static func make(paths: TeamPaths,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> @Sendable () -> TeamSecrets {
        if let dir = environment["INFINITUS_TEAM_DIR"], !dir.isEmpty {
            let secretsDir = paths.secretsDir
            return { FileSecrets(dir: secretsDir) }
        }
        return { KeychainTeamSecrets() }
    }
}
