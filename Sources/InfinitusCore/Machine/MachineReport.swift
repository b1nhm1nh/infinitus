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
        else if let n = sample.tempEntries, n >= 10_000 { out.append("temp directory holds \(n) entries") }
        return out
    }
}
