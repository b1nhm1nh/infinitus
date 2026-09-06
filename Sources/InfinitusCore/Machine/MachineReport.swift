import Foundation

/// One look at the machine (#115): the sample, the hooks with their live
/// instances, the runaways, the residue counts, the sessions, and the
/// warnings the guardian would push. `infinitusctl machine --json`
/// prints it; the Machine tab renders it.
public struct MachineReport: Equatable, Sendable, Codable {
    public struct Hook: Equatable, Sendable, Codable, Identifiable {
        public let registration: HookRegistration
        public let spawnsPerHour: Double
        public let live: HookInventory.Live
        public var id: String { registration.id }
        public init(registration: HookRegistration, spawnsPerHour: Double, live: HookInventory.Live) {
            self.registration = registration; self.spawnsPerHour = spawnsPerHour; self.live = live
        }
        public var risky: Bool { registration.heavy && spawnsPerHour >= 100 }
        public var stuck: Bool { live.instances >= 50 || live.oldestSeconds >= 600 || live.uninterruptible > 0 }
    }
    public struct ResidueCounts: Equatable, Sendable, Codable {
        public var staleSockets = 0
        public var staleSessionEnvs = 0
        public var tempEntries: Int?
        public var tempByOwner: [String: Int]?
        public var transcriptsBytes = 0
        public var pluginCacheBytes = 0
        public var memBytes = 0
        public init() {}
    }

    public var sample: MachineSample
    public var hooks: [Hook]
    public var runaways: [Runaways.Runaway]
    public var residue: ResidueCounts
    public var sessions: [SessionHealth]
    public var warnings: [String]

    public init(sample: MachineSample, hooks: [Hook], runaways: [Runaways.Runaway],
                residue: ResidueCounts, sessions: [SessionHealth], warnings: [String]) {
        self.sample = sample; self.hooks = hooks; self.runaways = runaways
        self.residue = residue; self.sessions = sessions; self.warnings = warnings
    }

    /// The warnings a sample earns, in the order the tab lists them.
    public static func warnings(sample: MachineSample, hooks: [Hook], newcomers: [HookRegistration]) -> [String] {
        var out: [String] = []
        for hook in newcomers {
            out.append("new hook: \(hook.owner) on \(hook.event) (\(hook.source.label))")
        }
        // One script registered on several events reports the same live
        // instances under each registration: one warning per owner.
        var seenOwners = Set<String>()
        let stuck = hooks.filter(\.stuck).sorted(by: { $0.live.instances > $1.live.instances })
            .filter { seenOwners.insert($0.registration.owner).inserted }
        for hook in stuck.prefix(3) {
            out.append("\(hook.registration.owner) has \(hook.live.instances) instances (oldest \(hook.live.oldestSeconds / 60) min, \(hook.live.uninterruptible) stuck)")
        }
        if sample.swapPct >= 90 { out.append("swap \(Int(sample.swapPct))% full") }
        if sample.uninterruptible >= 50 { out.append("\(sample.uninterruptible) processes in uninterruptible wait") }
        if sample.tempEntries == nil, sample.tempListSeconds > 0 { out.append("temp directory listing timed out") }
        else if let n = sample.tempEntries, n >= 10_000 { out.append("temp directory holds \(n) entries" + tempBreakdown(sample.tempByOwner)) }
        out += fanOut(hooks)
        return out
    }

    /// Which mute a pushed warning answers to (Settings › Machine: the
    /// hook and temp-directory notifications can be silenced separately;
    /// the pane keeps showing every warning).
    public enum WarningKind: Equatable, Sendable { case hooks, temp, other }
    public static func warningKind(_ warning: String) -> WarningKind {
        if warning.hasPrefix("new hook:") || warning.contains(" instances (") || warning.contains(" commands on every ") { return .hooks }
        if warning.hasPrefix("temp directory") { return .temp }
        return .other
    }

    /// " (pip 9600, python 12814, other 1500)" — owners with a share worth naming.
    public static func tempBreakdown(_ by: [String: Int]?) -> String {
        guard let by else { return "" }
        let parts = by.filter { $0.value >= 100 }.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// One owner registering several commands under the same event and
    /// matcher spawns all of them on every matching call — Claude Code
    /// evaluates each command's own guard only after spawning it (#115
    /// item 8: five `if: Bash(git …)` entries = five bash+python per
    /// Bash call). Reported as effective spawns per event.
    static func fanOut(_ hooks: [Hook]) -> [String] {
        var counts: [String: (owner: String, event: String, matcher: String, n: Int)] = [:]
        for hook in hooks {
            let r = hook.registration
            let key = "\(r.owner)|\(r.event)|\(r.matcher ?? "")"
            counts[key, default: (r.owner, r.event, r.matcher ?? "", 0)].n += 1
        }
        return counts.values.filter { $0.n >= 3 }.sorted { $0.n > $1.n }.prefix(3).map {
            "\($0.owner) runs \($0.n) commands on every \($0.event)\($0.matcher.isEmpty ? "" : " \($0.matcher)") call"
        }
    }
}
