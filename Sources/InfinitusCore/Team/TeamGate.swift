import Foundation

/// Spec §2.2: Create team, Accept invite and Request to join are disabled
/// until the biometric lock is on. One check for every entry point — the
/// CLI (TeamCommand), the Team pane (plan 5), the phone (plan 8) — so the
/// rule and its copy live in one place.
public enum TeamGate {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// The copy the surface shows next to its disabled action.
        case needsLock(String)
    }

    public static let reason = "Turn on biometric unlock first"

    /// `INFINITUS_LOCK_GATE=open` opens the gate: CI's e2e drives a team
    /// through the debug app and the CLI and can't answer a Touch ID
    /// prompt, and a debug binary's prefs domain is invisible to the CLI.
    /// The lock is a UI gate on the user's own Mac, not a security
    /// boundary — whoever has the shell has the files — so the hatch
    /// hides nothing; it is still never set by shipped launchers.
    public static let bypassVariable = "INFINITUS_LOCK_GATE"

    /// `lockEnabled` nil = this platform has no lock yet (Linux until the
    /// passphrase lock ships): open, by design, not by omission.
    public static func check(lockEnabled: Bool?,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Verdict {
        if environment[bypassVariable] == "open" { return .allowed }
        switch lockEnabled {
        case nil, true?: return .allowed
        case false?: return .needsLock(reason)
        }
    }
}
