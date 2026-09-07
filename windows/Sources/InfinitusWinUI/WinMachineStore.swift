import Foundation
import InfinitusCore
#if os(Windows)
import WinSDK
#endif

/// Windows half of Settings › Machine (#115): prefs, the Mac's
/// `paneShown` gate, and one on-demand sample assembled from
/// InfinitusCore (`MachineReport`, `HookInventory`, `Runaways`,
/// `Residue`, `SessionHealth`, `ClaudeSessions`). No timer — the
/// pane samples on activate and on Sample Now.
public enum WinMachineStore {
    public static var url: URL {
        WinSettingsStore.infinitusHome.appendingPathComponent("machine.json")
    }

    public struct Prefs: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var notifyHooks: Bool
        public var notifyTemp: Bool
        public var idleHours: Double
        public var showPane: Bool
        public var hookFingerprint: [String]
        public init(enabled: Bool = true, notifyHooks: Bool = true, notifyTemp: Bool = true,
                    idleHours: Double = 12, showPane: Bool = false, hookFingerprint: [String] = []) {
            self.enabled = enabled
            self.notifyHooks = notifyHooks
            self.notifyTemp = notifyTemp
            self.idleHours = idleHours
            self.showPane = showPane
            self.hookFingerprint = hookFingerprint
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, notifyHooks = "notify_hooks", notifyTemp = "notify_temp"
            case idleHours = "idle_hours", showPane = "show_pane"
            case hookFingerprint = "hook_fingerprint"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Prefs()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            notifyHooks = try c.decodeIfPresent(Bool.self, forKey: .notifyHooks) ?? d.notifyHooks
            notifyTemp = try c.decodeIfPresent(Bool.self, forKey: .notifyTemp) ?? d.notifyTemp
            idleHours = try c.decodeIfPresent(Double.self, forKey: .idleHours) ?? d.idleHours
            showPane = try c.decodeIfPresent(Bool.self, forKey: .showPane) ?? d.showPane
            hookFingerprint = try c.decodeIfPresent([String].self, forKey: .hookFingerprint) ?? d.hookFingerprint
        }
    }

    /// Same gate as `MachineModel.paneShown`: debug builds always show
    /// the pane; a release needs `INFINITUS_SHOW_MACHINE_PANE=1` or
    /// `show_pane` in machine.json (the Windows stand-in for
    /// `defaults write run.infinitus show_machine_pane -bool YES`).
    public static var paneShown: Bool {
        #if DEBUG
        return true
        #else
        if ProcessInfo.processInfo.environment["INFINITUS_SHOW_MACHINE_PANE"] == "1" { return true }
        return load().showPane
        #endif
    }

    public static func load(from url: URL = url) -> Prefs {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(Prefs.self, from: data) else {
            return Prefs()
        }
        return prefs
    }

    public static func save(_ prefs: Prefs, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(prefs).write(to: url, options: .atomic)
    }

    public static func userSettingsURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/.claude/settings.json")
    }

    /// One sample. Process listing is Windows glue; every number and
    /// warning after that is InfinitusCore. Darwin-only pieces
    /// (`MachineSampler.collect`, `Residue.openPaths`, `Runaways.kill`)
    /// are not called.
    public static func sample(prefs: Prefs, countTemp: Bool = true,
                              home: String = NSHomeDirectory()) -> (report: MachineReport, prefs: Prefs, parked: [String]) {
        let claudeDir = ClaudeSessions.configHome(home: home)
        let tempDir = ProcessInfo.processInfo.environment["TMPDIR"]
            ?? ProcessInfo.processInfo.environment["TEMP"]
            ?? NSTemporaryDirectory()
        let records = ClaudeSessions.list(claudeDir: claudeDir)
        let sessionPids = Set(records.map { Int($0.pid) })
        let cwds = Array(Set(records.map(\.cwd)))

        let (sample, rows) = WinMachineSampler.collect(sessionPids: sessionPids, tempDir: tempDir, countTemp: countTemp)

        let hookRegs = HookInventory.scan(home: home, projectDirs: cwds)
        let hooks = hookRegs.map { reg in
            MachineReport.Hook(registration: reg,
                               spawnsPerHour: HookInventory.spawnsPerHour(event: reg.event, liveSessions: sessionPids.count),
                               live: HookInventory.live(of: reg, rows: rows))
        }
        let runaways = Runaways.flagged(rows: rows, sessionPids: sessionPids)

        var residue = MachineReport.ResidueCounts()
        let sockDir = (tempDir as NSString).appendingPathComponent("cc-socks")
        residue.staleSockets = Residue.staleSockets(dir: sockDir, alive: { ClaudeSessions.isAlive(Int32($0)) }).count
        residue.staleSessionEnvs = Residue.staleSessionEnvs(dir: home + "/.claude/session-env",
                                                            liveSessionIds: Set(records.map(\.sessionId))).count
        residue.tempEntries = sample.tempEntries
        residue.tempByOwner = sample.tempByOwner
        residue.transcriptsBytes = Residue.size(of: home + "/.claude/projects")
        residue.pluginCacheBytes = Residue.size(of: home + "/.claude/plugins/cache")
        residue.memBytes = Residue.size(of: home + "/.claude-mem")

        let sessions = SessionHealth.build(
            rows: rows, records: records,
            name: { SessionNaming.displayName(name: $0.name, autoName: nil, cwd: $0.cwd) },
            lastActivity: { _ in nil })

        let fingerprint = Set(hookRegs.map(\.id))
        let previous = Set(prefs.hookFingerprint)
        let newcomers: [HookRegistration]
        var nextPrefs = prefs
        if prefs.hookFingerprint.isEmpty {
            newcomers = []
            nextPrefs.hookFingerprint = Array(fingerprint)
        } else {
            newcomers = HookInventory.newcomers(hookRegs, since: previous)
            nextPrefs.hookFingerprint = Array(previous.union(fingerprint))
        }

        let pipSpawner = HookInventory.spawner(of: "pip install", rows: rows, registrations: hookRegs)
        let pipTarget = MachineReport.pipInstallTarget(rows: rows, home: home)
        var report = MachineReport(sample: sample, hooks: hooks, runaways: runaways,
                                   residue: residue, sessions: sessions, warnings: [])
        report.warnings = MachineReport.warnings(sample: sample, hooks: hooks, newcomers: newcomers,
                                                 pipSpawner: pipSpawner, pipTarget: pipTarget)

        let parked = parkedOwners(home: home)
        return (report, nextPrefs, parked)
    }

    public static func parkedOwners(home: String = NSHomeDirectory()) -> [String] {
        guard let data = try? Data(contentsOf: userSettingsURL(home: home)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return HookKillSwitch.parkedOwners(in: object)
    }

    public static func disableHook(owner: String, home: String = NSHomeDirectory()) -> String {
        do {
            let (backup, moved) = try HookKillSwitch.apply({ HookKillSwitch.disable(owner: owner, in: $0) },
                                                           to: userSettingsURL(home: home))
            return "moved \(moved) registration\(moved == 1 ? "" : "s") out of settings.json (backup \(backup.lastPathComponent))"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    public static func restoreHook(owner: String, home: String = NSHomeDirectory()) -> String {
        do {
            let (_, moved) = try HookKillSwitch.apply({ HookKillSwitch.restore(owner: owner, in: $0) },
                                                      to: userSettingsURL(home: home))
            return "restored \(moved) registration\(moved == 1 ? "" : "s")"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    public static func reclaim(home: String = NSHomeDirectory()) -> String {
        let tempDir = ProcessInfo.processInfo.environment["TMPDIR"]
            ?? ProcessInfo.processInfo.environment["TEMP"]
            ?? NSTemporaryDirectory()
        let liveSessionIds = Set(ClaudeSessions.list(claudeDir: ClaudeSessions.configHome(home: home)).map(\.sessionId))
        var items: [Residue.Item] = []
        items += Residue.staleSockets(dir: (tempDir as NSString).appendingPathComponent("cc-socks"),
                                      alive: { ClaudeSessions.isAlive(Int32($0)) })
        items += Residue.staleSessionEnvs(dir: home + "/.claude/session-env", liveSessionIds: liveSessionIds)
        // Residue.openPaths is Darwin/lsof — without it the Mac skips the
        // temp reclaim rather than deleting files a process still holds.
        let failures = Residue.reclaim(items)
        let removed = items.count - failures.count
        return "removed \(removed)" + (failures.isEmpty ? "" : ", \(failures.count) failed")
            + " (temp reclaim skipped — no lsof on Windows)"
    }

    public static func terminate(pid: Int) -> String {
        #if os(Windows)
        guard pid > 4 else { return "pid \(pid) is protected — nothing sent" }
        guard let handle = OpenProcess(DWORD(0x0001), false, DWORD(UInt32(truncatingIfNeeded: pid))) else {
            return "couldn't open pid \(pid)"
        }
        defer { CloseHandle(handle) }
        let ok = TerminateProcess(handle, 1)
        return ok ? "pid \(pid) is gone" : "pid \(pid) is still alive"
        #else
        return "pid \(pid) — terminate is Windows-only"
        #endif
    }
}

/// Lines the Machine pane paints. Pure, so the HWND-free tests can
/// pin the copy against a synthetic `MachineReport`.
public enum WinMachineText {
    public struct HookGroup: Equatable, Sendable {
        public let owner: String
        public let kind: HookRegistration.OwnerKind
        public let events: [String]
        public let spawnsPerHour: Double
        public let heavy: Bool
        public let instances: Int
        public let helpers: Int
        public let oldestSeconds: Int
        public let stuckCount: Int
        public let registrationCount: Int
    }

    public static func summaryLines(_ s: MachineSample) -> [(label: String, value: String)] {
        let temp: String
        if let n = s.tempEntries { temp = "\(n)" } else { temp = "Listing timed out" }
        return [
            ("Cores", "\(s.cores)"),
            ("Commit", "\(s.swapUsedMB) / \(s.swapTotalMB) MB"),
            ("Processes", "\(s.processes) total, \(s.running) running, \(s.uninterruptible) uninterruptible, \(s.zombies) zombies"),
            ("Temp entries", temp),
            ("Claude sessions", "\(s.claudeRSSMB) MB resident"),
        ]
    }

    public static func hookGroups(_ report: MachineReport) -> [HookGroup] {
        var byOwner: [String: [MachineReport.Hook]] = [:]
        for hook in report.hooks { byOwner[hook.registration.owner, default: []].append(hook) }
        var groups: [HookGroup] = []
        for (owner, hooks) in byOwner {
            guard let first = hooks.first else { continue }
            var events = Set<String>()
            var spawns = 0.0, heavy = false, instances = 0, helpers = 0, oldest = 0, stuck = 0
            for hook in hooks {
                events.insert(hook.registration.event)
                spawns += hook.spawnsPerHour
                if hook.registration.heavy { heavy = true }
                instances = max(instances, hook.live.instances)
                helpers = max(helpers, hook.live.helpers)
                oldest = max(oldest, hook.live.oldestSeconds)
                if hook.stuck { stuck += 1 }
            }
            groups.append(HookGroup(owner: owner, kind: first.registration.ownerKind, events: events.sorted(),
                                    spawnsPerHour: spawns, heavy: heavy, instances: instances, helpers: helpers,
                                    oldestSeconds: oldest, stuckCount: stuck, registrationCount: hooks.count))
        }
        return groups.sorted { $0.owner < $1.owner }
    }

    public static func kindLabel(_ kind: HookRegistration.OwnerKind) -> String {
        switch kind {
        case .brew: return "Brew"
        case .vendored: return "Vendored"
        case .handInstalled: return "Hand-installed"
        case .plugin: return "Plugin"
        case .unknown: return "Unknown"
        }
    }

    public static func hookLines(_ report: MachineReport) -> [String] {
        let groups = hookGroups(report)
        if groups.isEmpty { return ["No hook registrations"] }
        return groups.map { g in
            var line = "\(g.owner) (\(kindLabel(g.kind)))"
            if g.heavy { line += " Heavy" }
            line += " — " + g.events.joined(separator: ", ") + " · \(Int(g.spawnsPerHour))/h expected"
            line += " · \(g.instances) live" + (g.helpers > 0 ? " + \(g.helpers) helpers" : "")
            line += " · oldest \(g.oldestSeconds / 60) min"
            if g.stuckCount > 0 { line += " · \(g.stuckCount) stuck" }
            return line
        }
    }

    public static func runawayLines(_ report: MachineReport) -> [String] {
        if report.runaways.isEmpty { return ["Nothing flagged"] }
        return report.runaways.map { r in
            "\(r.rule) \(r.why) · \(r.rssMB) MB · \(r.elapsedSeconds / 60) min · pid \(r.pid) · \(r.command)"
        }
    }

    public static func residueLine(_ r: MachineReport.ResidueCounts) -> String {
        let temp = r.tempEntries.map { "\($0)" } ?? "?"
        return "\(r.staleSockets) stale sockets, \(r.staleSessionEnvs) stale session-env dirs, \(temp) temp entries"
            + MachineReport.tempBreakdown(r.tempByOwner)
    }

    public static func residueSizes(_ r: MachineReport.ResidueCounts) -> String {
        "transcripts \(bytes(r.transcriptsBytes)) · plugin cache \(bytes(r.pluginCacheBytes)) · claude-mem \(bytes(r.memBytes))"
    }

    public static func sessionLines(_ sessions: [SessionHealth]) -> [String] {
        if sessions.isEmpty { return ["No sessions"] }
        return sessions.map { s in
            let leaf = (s.cwd as NSString).lastPathComponent
            return "\(s.name) · \(s.ageSeconds / 60) min · \(s.rssMB) MB · \(Int(s.idleHours())) h idle · \(leaf)"
        }
    }

    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        return String(format: "%.1f GB", Double(n) / 1024 / 1024 / 1024)
    }
}

/// Process listing for the guardian. `MachineSampler.collect` is
/// Darwin/`ps`/`sysctl`; this is CreateToolhelp32Snapshot +
/// GlobalMemoryStatusEx. Rows still feed InfinitusCore summarizers.
public enum WinMachineSampler {
    public static func collect(sessionPids: Set<Int>, tempDir: String, countTemp: Bool = true) -> (MachineSample, [ProcessRow]) {
        let rows = processRows()
        let cores = processorCount()
        let swap = pageFileMB()
        let summary = MachineSampler.summarize(rows: rows, sessionPids: sessionPids)
        var sample = MachineSample(cores: cores, load1: 0, load5: 0,
                                   swapUsedMB: swap.used, swapTotalMB: swap.total,
                                   processes: rows.count, running: summary.running,
                                   uninterruptible: summary.uninterruptible, zombies: summary.zombies,
                                   windowServerCPU: 0, claudeRSSMB: summary.claudeRSSMB)
        if countTemp {
            let (by, seconds) = MachineSampler.countByOwner(tempDir, timeout: 10)
            sample.tempByOwner = by
            sample.tempEntries = by.map { $0.values.reduce(0, +) }
            sample.tempListSeconds = seconds
        }
        return (sample, rows)
    }

    #if os(Windows)
    private static func processorCount() -> Int {
        ProcessInfo.processInfo.processorCount
    }

    private struct MemoryStatusEx {
        var dwLength: DWORD = 0
        var dwMemoryLoad: DWORD = 0
        var ullTotalPhys: UInt64 = 0
        var ullAvailPhys: UInt64 = 0
        var ullTotalPageFile: UInt64 = 0
        var ullAvailPageFile: UInt64 = 0
        var ullTotalVirtual: UInt64 = 0
        var ullAvailVirtual: UInt64 = 0
        var ullAvailExtendedVirtual: UInt64 = 0
    }

    private typealias MemStatusFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    private static func pageFileMB() -> (used: Int, total: Int) {
        guard let fn: MemStatusFn = kernel32("GlobalMemoryStatusEx") else { return (0, 0) }
        var status = MemoryStatusEx()
        status.dwLength = DWORD(MemoryLayout<MemoryStatusEx>.size)
        let ok = withUnsafeMutableBytes(of: &status) { fn($0.baseAddress) != 0 }
        guard ok else { return (0, 0) }
        let total = Int(status.ullTotalPageFile / 1_048_576)
        let avail = Int(status.ullAvailPageFile / 1_048_576)
        return (max(0, total - avail), total)
    }

    private typealias SnapshotFn = @convention(c) (DWORD, DWORD) -> HANDLE?
    private typealias ProcessWalkFn = @convention(c) (HANDLE?, UnsafeMutableRawPointer?) -> Int32
    private typealias MemoryFn = @convention(c) (HANDLE?, UnsafeMutableRawPointer?, DWORD) -> Int32

    private struct MemoryCounters {
        var cb: DWORD = 0
        var PageFaultCount: DWORD = 0
        var PeakWorkingSetSize: UInt64 = 0
        var WorkingSetSize: UInt64 = 0
        var QuotaPeakPagedPoolUsage: UInt64 = 0
        var QuotaPagedPoolUsage: UInt64 = 0
        var QuotaPeakNonPagedPoolUsage: UInt64 = 0
        var QuotaNonPagedPoolUsage: UInt64 = 0
        var PagefileUsage: UInt64 = 0
        var PeakPagefileUsage: UInt64 = 0
        var PrivateUsage: UInt64 = 0
    }

    private static func kernel32<T>(_ name: String) -> T? {
        let wide = Array("kernel32.dll".utf16) + [0]
        let loaded = wide.withUnsafeBufferPointer { GetModuleHandleW($0.baseAddress) }
            ?? wide.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }
        guard let loaded, let raw = name.withCString({ GetProcAddress(loaded, $0) }) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private static func processRows() -> [ProcessRow] {
        let snapProcess: DWORD = 0x00000002
        guard let create: SnapshotFn = kernel32("CreateToolhelp32Snapshot"),
              let first: ProcessWalkFn = kernel32("Process32FirstW"),
              let next: ProcessWalkFn = kernel32("Process32NextW") else { return [] }
        let snap = create(snapProcess, 0)
        guard let snap, snap != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snap) }

        // PROCESSENTRY32W is 568 bytes on x64 (header + MAX_PATH WCHARs).
        var buf = [UInt8](repeating: 0, count: 1024)
        return buf.withUnsafeMutableBytes { raw -> [ProcessRow] in
            guard let base = raw.baseAddress else { return [] }
            // PROCESSENTRY32W on x64: 44-byte header + MAX_PATH WCHARs = 564.
            let entrySize = DWORD(564)
            base.storeBytes(of: entrySize, as: DWORD.self)
            guard first(snap, base) != 0 else { return [] }
            var rows: [ProcessRow] = []
            repeat {
                let pid = Int(base.load(fromByteOffset: 8, as: DWORD.self))
                let ppid = Int(base.load(fromByteOffset: 32, as: DWORD.self))
                let exeOffset = 44
                let exeCount = 260
                var chars: [UInt16] = []
                chars.reserveCapacity(64)
                for i in 0..<exeCount {
                    let c = base.load(fromByteOffset: exeOffset + i * 2, as: UInt16.self)
                    if c == 0 { break }
                    chars.append(c)
                }
                let exe = String(decoding: chars, as: UTF16.self)
                let (rssKB, elapsed, path) = details(pid: pid, exe: exe)
                rows.append(ProcessRow(pid: pid, ppid: ppid, stat: "S", rssKB: rssKB,
                                       elapsedSeconds: elapsed, cpu: 0, command: path))
                base.storeBytes(of: entrySize, as: DWORD.self)
            } while next(snap, base) != 0
            return rows
        }
    }

    private static func details(pid: Int, exe: String) -> (rssKB: Int, elapsed: Int, path: String) {
        let access = DWORD(0x1000) // PROCESS_QUERY_LIMITED_INFORMATION
        guard pid > 0, let handle = OpenProcess(access, false, DWORD(UInt32(truncatingIfNeeded: pid))) else {
            return (0, 0, exe)
        }
        defer { CloseHandle(handle) }
        var rssKB = 0
        if let fn: MemoryFn = kernel32("K32GetProcessMemoryInfo") {
            var counters = MemoryCounters()
            let cb = DWORD(MemoryLayout<MemoryCounters>.size)
            counters.cb = cb
            let ok = withUnsafeMutableBytes(of: &counters) { raw -> Bool in
                fn(handle, raw.baseAddress, cb) != 0
            }
            if ok { rssKB = Int(counters.WorkingSetSize / 1024) }
        }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        var elapsed = 0
        if GetProcessTimes(handle, &created, &exited, &kernel, &user) {
            let created100ns = (UInt64(created.dwHighDateTime) << 32) | UInt64(created.dwLowDateTime)
            // FILETIME is 100 ns since 1601; Unix is 1601→1970 = 11644473600 s.
            let createdUnix = Double(created100ns) / 10_000_000.0 - 11_644_473_600.0
            elapsed = max(0, Int(Date().timeIntervalSince1970 - createdUnix))
        }
        var pathBuf = [WCHAR](repeating: 0, count: 32768)
        var pathLen = DWORD(pathBuf.count)
        typealias QueryPathFn = @convention(c) (HANDLE?, DWORD, LPWSTR?, UnsafeMutablePointer<DWORD>?) -> Int32
        let path: String = pathBuf.withUnsafeMutableBufferPointer { buf in
            if let fn: QueryPathFn = kernel32("QueryFullProcessImageNameW"),
               fn(handle, 0, buf.baseAddress, &pathLen) != 0, pathLen > 0 {
                return String(decodingCString: buf.baseAddress!, as: UTF16.self)
            }
            return exe
        }
        return (rssKB, elapsed, path)
    }
    #else
    private static func processorCount() -> Int { 0 }
    private static func pageFileMB() -> (used: Int, total: Int) { (0, 0) }
    private static func processRows() -> [ProcessRow] { [] }
    #endif
}
