import Foundation
import IOKit.pwr_mgt

/// Prevents idle SYSTEM sleep while Claude Code sessions are mid-turn —
/// the native `caffeinate -i`, in-process (docs/TODO.md item; the
/// Caffeine.app path was dropped 2026-08-29: it meant writing another
/// app's prefs). Display sleep stays allowed on purpose: the screen can
/// go dark while the agents keep working. Visible in `pmset -g assertions`
/// as "Infinitus: Claude Code sessions working".
@MainActor
final class KeepAwake {
    private var assertionID: IOPMAssertionID = 0
    private(set) var active = false

    func update(wanted: Bool, busyCount: Int) {
        let should = wanted && busyCount > 0
        if should, !active {
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Infinitus: Claude Code sessions working" as CFString, &id)
            if rc == kIOReturnSuccess {
                assertionID = id
                active = true
            }
        } else if !should, active {
            IOPMAssertionRelease(assertionID)
            active = false
        }
    }
}
