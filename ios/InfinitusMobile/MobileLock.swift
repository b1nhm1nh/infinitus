import Foundation
import LocalAuthentication

/// The phone's own biometric switch for the Team tab (spec §2.2, scoped
/// to the tab this round; app-wide is #55). `.deviceOwnerAuthentication`
/// so the passcode is the fallback the OS itself offers. A fresh
/// LAContext per prompt: a reused one answers from its own cache.
@MainActor
final class MobileLock: ObservableObject {
    static let shared = MobileLock()
    static let enabledKey = "team_lock"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            locked = enabled
        }
    }
    @Published private(set) var locked: Bool

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey)
        enabled = on
        locked = on
    }

    var methodName: String {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return "passcode" }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "passcode"
        }
    }

    func unlock() async -> Bool {
        guard enabled else { locked = false; return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Show your team")) ?? false
        if ok { locked = false }
        return ok
    }

    func relock() { if enabled { locked = true } }
}
