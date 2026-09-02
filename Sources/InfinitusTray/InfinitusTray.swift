import Foundation
import InfinitusCore

// The Omarchy/Linux face of Infinitus: a Waybar `custom` module
// (`return-type: json`) over the same InfinitusCore the macOS app uses.
// Everything engine-side stays behind `cswap … --json` subprocesses —
// the architecture rule holds on both OSes. packaging/omarchy carries
// the module config; `status` is the interval exec, `rotate` the click.

/// Waybar custom-module payload (one line of JSON on stdout).
struct WaybarPayload: Encodable {
    let text: String
    let tooltip: String
    let `class`: String
    let percentage: Int?
}

// Structured feed for the Quickshell panel (`panel` command). Themed
// strings are rendered here so QML stays a dumb renderer; pcts stay raw
// numbers so the gauges can draw. NOT pango-escaped — this is data, not
// Waybar markup.
struct PanelWindow: Encodable {
    let label: String
    let pct: Int          // used, 0–100
    let reset: String?
    /// Behind-pace glow 0…1 (GaugeMath.chillDepth); omitted when calm.
    let chill: Double?
}

struct PanelAccount: Encodable {
    let number: Int
    let name: String
    let plan: String?     // themed plan label
    let marker: String
    let active: Bool
    let disabled: Bool
    let isNext: Bool
    let note: String?     // sentinel (relogin etc.), themed
    let deadLine: String? // themed "☠ fallen — 🩸 2h 25m"
    /// Binding window in the 90s (alive): the panel row flashes.
    let critical: Bool
    let windows: [PanelWindow]
}

struct PanelTheme: Encodable {
    let id: String
    let name: String
}

/// Present only when EVERY account is at a limit: the account that
/// recovers first (raw ISO instant — the panel ticks the countdown
/// itself) and how many limit-stopped sessions wait to be resumed.
struct PanelRecovery: Encodable {
    let number: Int
    let at: String
    let waiting: Int
}

struct PanelPayload: Encodable {
    let schemaVersion: Int
    let themeId: String
    let title: String       // bar-style active line for the panel header
    let sessionsLine: String?
    let activeNumber: Int?
    let accounts: [PanelAccount]
    let themes: [PanelTheme]
    let nextRecovery: PanelRecovery?
    /// Compact session-progress rows (issue #13 step 4) — busy/waiting
    /// sessions, capped, additive field so older panels ignore it.
    let sessions: [SessionPanelRow]
    let error: String?
}

@main
struct InfinitusTray {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "status" : args.removeFirst()
        var themeID = "off"
        var remaining = false
        var engineOrder = false
        var positional: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--theme" where i + 1 < args.count:
                themeID = args[i + 1]
                i += 1
            case "--remaining":
                remaining = true
            case "--engine-order":
                engineOrder = true
            case let a where !a.hasPrefix("-"):
                positional.append(a)
            default:
                fail("unknown option: \(args[i])")
            }
            i += 1
        }
        switch command {
        case "status":
            await status(themeID: themeID, remaining: remaining)
        case "panel":
            await panel(themeID: themeID, engineOrder: engineOrder)
        case "rotate":
            await rotate()
        case "switch":
            await switchTo(positional.first)
        case "disable", "enable":
            await setRotation(positional.first, enabled: command == "enable")
        case "themes":
            for theme in RowTheme.builtins {
                print("\(theme.id)\t\(theme.name)")
            }
        case "help", "--help", "-h":
            print(help)
        default:
            fail("unknown command: \(command)\n\(help)")
        }
    }

    static let help = """
    infinitus-tray — Waybar module for the claude-swap fleet (Omarchy/Linux)

      status [--theme ID] [--remaining]   Waybar JSON: active account + fleet tooltip
      panel [--theme ID] [--engine-order] structured fleet JSON for the Quickshell panel
      rotate                              switch to the next account
      switch <n>                          switch to account n
      disable <n> / enable <n>            hold an account out of rotation / return it
      themes                              list built-in theme ids

    Wire-up (packaging/omarchy/waybar-infinitus.jsonc):
      "custom/infinitus": exec `infinitus-tray status --theme rpg`,
      on-click `infinitus-tray rotate && pkill -RTMIN+8 waybar`.
    """

    // MARK: status

    static func status(themeID: String, remaining: Bool) async {
        guard let bin = CswapLocator.locate() else {
            emit(WaybarPayload(
                text: "\(TitleFormatter.icon) no cswap",
                tooltip: "cswap not found — install claude-swap:\nuv tool install claude-swap",
                class: "error", percentage: nil))
            return
        }
        let theme = RowTheme.builtins.first { $0.id == themeID } ?? .off
        do {
            let (list, raw) = try await CswapCLI(binaryPath: bin).accountListRaw()
            // Utilization history rides the Waybar heartbeat — one
            // append per fresh engine usage poll (todo 2026-09-01).
            TrayHistory.record(accounts: list.accounts, enginePath: bin)
            // Fleet mirror export (#9 phase 1 parity — macOS's
            // MirrorExporter). Own throttle, own demo-cswap gate.
            let claudeDir = ClaudeSessions.configHome()
            let session = sessionRows(claudeDir: claudeDir, now: Date())
            TrayMirror.export(raw: raw, sessions: session.rows,
                              enginePath: bin, prefs: FleetPrefs(themeID: theme.id),
                              progressByPid: session.progressByPid)
            // Engine installed, fleet empty: a bare glyph with no
            // tooltip reads as broken — onboard instead.
            guard !list.accounts.isEmpty else {
                // Onboarding parity with the macOS FirstAccountCard
                // (todo 2026-09-01): name the login `cswap add` adopts.
                var tip = "the engine has no accounts yet — "
                let claude = ClaudeCLIDetect.info()
                if let email = claude.email {
                    tip += "Claude Code is signed in as \(email); "
                        + "adopt it with:\ncswap add"
                } else {
                    tip += "sign in with Claude Code, then:\ncswap add"
                }
                emit(WaybarPayload(
                    text: "\(TitleFormatter.icon) no accounts",
                    tooltip: tip,
                    class: "warning", percentage: nil))
                return
            }
            let now = Date()
            let active = list.accounts.first { $0.active }
            let prefs = TitlePrefs(showAccountName: true, titlePct: "both",
                                   titleScoped: false, titleRemaining: remaining)
            let recovery = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts)
            let rows = list.accounts.map { row($0, list: list, recovery: recovery, theme: theme, now: now) }
            var tooltip = rows.joined(separator: "\n")
            if let live = list.liveSessions {
                tooltip += "\n" + SessionSummary.tooltip(live)
            }
            let cls: String
            if let active, AccountVitals.isDead(active.usage) { cls = "dead" }
            else if let active, active.usageStatus != "ok" { cls = "warning" }
            else { cls = "ok" }
            emit(WaybarPayload(
                text: TitleFormatter.format(account: active, prefs: prefs, now: now),
                tooltip: tooltip,
                class: cls,
                percentage: (active?.usage?.fiveHour?.pct).map { Int($0.rounded()) }))
        } catch {
            emit(WaybarPayload(
                text: "\(TitleFormatter.icon) engine error",
                tooltip: pango("\(error)"), class: "error", percentage: nil))
        }
    }

    /// One themed fleet line: marker, slot, name, plan, then either the
    /// sentinel note, the dead cause + revive reset, or the usage windows.
    ///
    /// `recovery` is the corrected next-recovery (RecoveryMath), not
    /// `list.nextRecovery` verbatim — the engine's advisory skips the
    /// active account, which misnames the reviver when the active one is
    /// both dead and soonest (user report 2026-09-02).
    static func row(_ a: Account, list: AccountList, recovery: NextRecovery?, theme: RowTheme, now: Date) -> String {
        let name = a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
        let marker: String
        if a.active { marker = theme.activeIcon.isEmpty ? "●" : theme.activeIcon }
        else if a.number == list.nextCandidate { marker = theme.nextIcon.isEmpty ? "▶" : theme.nextIcon }
        // All limited: hollow marker on the first to recover (the macOS
        // popup's gray/orange triangle).
        else if list.nextCandidate == nil, a.number == recovery?.number { marker = "▷" }
        else { marker = "·" }
        var parts = ["\(marker) \(theme.slotPrefix)\(a.number) \(name)"]
        if let plan = a.plan { parts.append(theme.planLabel(plan, compact: true)) }
        if let note = SentinelNotes.short(for: a.usageStatus) {
            parts.append(note)
        } else if let cause = AccountVitals.cause(a.usage) {
            var s = "\(theme.deadMarker) \(theme.deadVerb)"
            if let reset = ResetLabel.label(resetsAt: cause.resetsAt,
                                           countdown: cause.countdown,
                                           clock: cause.clock, now: now) {
                s += " — \(theme.revivePrefix)\(reset)"
            }
            parts.append(s)
        } else {
            if let w = a.usage?.fiveHour {
                var s = "\(theme.sessionLabel) \(Int(w.pct.rounded()))%"
                if let r = ResetLabel.short(w, now: now) { s += " (\(r))" }
                parts.append(s)
            }
            if let w = a.usage?.sevenDay, let pct = WeeklyRoll.displayPct(w, now: now) {
                var s = "\(theme.weeklyLabel) \(Int(pct.rounded()))%"
                if let r = ResetLabel.compact(w, now: now) { s += " (\(r))" }
                parts.append(s)
            }
            for w in a.usage?.scoped ?? [] {
                guard let pct = WeeklyRoll.displayPct(w, now: now) else { continue }
                parts.append("\(theme.scopedPrefix)\(theme.modelName(w.name)) \(Int(pct.rounded()))%")
            }
        }
        return parts.joined(separator: "  ")
    }

    /// Session progress rows shared by the panel and the fleet mirror
    /// export in `status()` (issue #13 step 4 / #9 parity): busy/waiting
    /// first, busy before waiting, capped at 6.
    /// The panel rows plus the per-pid progress the mirror carries for
    /// the phone's sessions card (#9 phase D2) — one read, two consumers.
    static func sessionRows(claudeDir: URL, now: Date)
        -> (rows: [SessionPanelRow], progressByPid: [Int: SessionProgress]) {
        let sessionRecords = ClaudeSessions.list(claudeDir: claudeDir)
            .filter { $0.status == "busy" || $0.status == "waiting" }
            .sorted { a, _ in a.status == "busy" }
        let selectedSessions = Array(sessionRecords.prefix(6))
        var progressCache = SessionProgressCache.load()
        var progressByPid: [Int: SessionProgress] = [:]
        let sessions = selectedSessions.map { record -> SessionPanelRow in
            let stamp = SessionProgressCache.stamp(sessionId: record.sessionId,
                                                   cwd: record.cwd, claudeDir: claudeDir)
            let progress: SessionProgress
            if let entry = progressCache[record.sessionId],
               entry.size == stamp.size, entry.mtime == stamp.mtime {
                progress = entry.progress
            } else {
                progress = SessionProgress.read(sessionId: record.sessionId,
                                                cwd: record.cwd, claudeDir: claudeDir)
                progressCache[record.sessionId] = .init(size: stamp.size, mtime: stamp.mtime,
                                                        progress: progress)
            }
            progressByPid[Int(record.pid)] = progress
            return SessionPanelRow.make(record: record, progress: progress, now: now)
        }
        SessionProgressCache.save(progressCache)
        return (sessions, progressByPid)
    }

    // MARK: panel

    /// Structured fleet JSON for the Quickshell popup panel.
    static func panel(themeID: String, engineOrder: Bool = false) async {
        let theme = RowTheme.builtins.first { $0.id == themeID } ?? .off
        let themes = RowTheme.builtins.map { PanelTheme(id: $0.id, name: $0.name) }
        func emitError(_ message: String) {
            emitPanel(PanelPayload(
                schemaVersion: 1, themeId: theme.id,
                title: "\(TitleFormatter.icon) \(message)", sessionsLine: nil,
                activeNumber: nil, accounts: [], themes: themes,
                nextRecovery: nil, sessions: [], error: message))
        }
        guard let bin = CswapLocator.locate() else {
            emitError("cswap not found")
            return
        }
        do {
            let (list, raw) = try await CswapCLI(binaryPath: bin).accountListRaw()
            let now = Date()
            let active = list.accounts.first { $0.active }
            let prefs = TitlePrefs(showAccountName: true, titlePct: "both",
                                   titleScoped: false, titleRemaining: false)
            // Display order (todo 2026-09-01, matches the macOS popup):
            // active, next candidate, then most headroom first —
            // display-only, engine slots untouched. --engine-order opts out.
            let ordered = engineOrder ? list.accounts
                : DisplayOrder.sort(list.accounts,
                                    active: active?.number,
                                    next: list.nextCandidate)
            // Corrected, not the engine's verbatim value: its advisory
            // skips the active account, which misnames the reviver when
            // the active one is both dead and soonest (2026-09-02).
            let recovery = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts)
            let accounts = ordered.map { a -> PanelAccount in
                let name = a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
                let marker: String
                if a.active { marker = theme.activeIcon.isEmpty ? "●" : theme.activeIcon }
                else if a.number == list.nextCandidate { marker = theme.nextIcon.isEmpty ? "▶" : theme.nextIcon }
                else if list.nextCandidate == nil, a.number == recovery?.number { marker = "▷" }
                else { marker = "·" }
                var note: String?
                var deadLine: String?
                var deadBySession = false
                var critical = false
                var windows: [PanelWindow] = []
                if let s = SentinelNotes.short(for: a.usageStatus) {
                    note = s
                } else if let cause = AccountVitals.cause(a.usage) {
                    deadBySession = cause.kind == .session
                    var s = "\(theme.deadMarker) \(theme.deadVerb)"
                    if let reset = ResetLabel.label(resetsAt: cause.resetsAt,
                                                   countdown: cause.countdown,
                                                   clock: cause.clock, now: now) {
                        s += " — \(theme.revivePrefix)\(reset)"
                    }
                    deadLine = s
                } else if (PushTriggers.worstPlanPct(a.usage) ?? 0) >= 90 {
                    // Dying flash (user 2026-09-01): alive, binding
                    // window in the 90s.
                    critical = true
                }
                func paceChill(_ w: UsageWindow) -> Double? {
                    let c = GaugeMath.chillDepth(usedPct: w.pct,
                                                 expectedPct: w.expectedPct,
                                                 ahead: w.aheadOfPace)
                    return c > 0 ? c : nil
                }
                if let w = a.usage?.fiveHour, !deadBySession {
                    // The 5h bar stays calm on macOS too — pace effects
                    // are weekly/model signals. Dead-by-5h drops it: the
                    // death line IS the 5h story (user 2026-09-01).
                    windows.append(PanelWindow(label: theme.sessionLabel,
                                               pct: Int(w.pct.rounded()),
                                               reset: ResetLabel.short(w, now: now),
                                               chill: nil))
                }
                if let w = a.usage?.sevenDay, let pct = WeeklyRoll.displayPct(w, now: now) {
                    // Dead-by-5h keeps the weekly gauge, skips its timer.
                    windows.append(PanelWindow(label: theme.weeklyLabel,
                                               pct: Int(pct.rounded()),
                                               reset: deadBySession ? nil
                                                   : ResetLabel.compact(w, now: now),
                                               chill: paceChill(w)))
                }
                for w in a.usage?.scoped ?? [] {
                    guard let pct = WeeklyRoll.displayPct(w, now: now) else { continue }
                    windows.append(PanelWindow(
                        label: "\(theme.scopedPrefix)\(theme.modelName(w.name))",
                        pct: Int(pct.rounded()), reset: nil,
                        chill: paceChill(w)))
                }
                return PanelAccount(
                    number: a.number, name: name,
                    plan: a.plan.map { theme.planLabel($0, compact: true) },
                    marker: marker, active: a.active,
                    disabled: a.disabled ?? false,
                    isNext: a.number == list.nextCandidate,
                    note: note, deadLine: deadLine, critical: critical,
                    windows: windows)
            }
            // All-limited: the engine names the first account to recover;
            // the waiting count reuses the resume mechanism's own
            // stopped-session detection (Claude Code's files only —
            // never engine internals).
            let claudeDir = ClaudeSessions.configHome()
            var panelRecovery: PanelRecovery?
            if list.nextCandidate == nil, let rec = recovery {
                let stopped = Transcript.findStopped(
                    sessions: ClaudeSessions.list(claudeDir: claudeDir), claudeDir: claudeDir)
                panelRecovery = PanelRecovery(number: rec.number, at: rec.at,
                                              waiting: stopped.count)
            }
            // Session progress rows (issue #13 step 4): busy/waiting
            // first (same ordering as the macOS wall's session board),
            // capped at 6. No self-skip here — neither the macOS popover
            // nor the wall board excludes the tray's/app's own lineage,
            // so this doesn't invent one either (flagged as a concern).
            let (sessions, progressByPid) = sessionRows(claudeDir: claudeDir, now: now)
            // Fleet mirror export (#9 phase 1 parity — macOS's
            // MirrorExporter). Shares the throttle sidecar with status().
            TrayMirror.export(raw: raw, sessions: sessions, enginePath: bin,
                              prefs: FleetPrefs(themeID: theme.id, sortByHeadroom: !engineOrder),
                              progressByPid: progressByPid, now: now)
            emitPanel(PanelPayload(
                schemaVersion: 1, themeId: theme.id,
                title: list.accounts.isEmpty
                    ? "\(TitleFormatter.icon) no accounts — cswap add"
                    : TitleFormatter.format(account: active, prefs: prefs, now: now),
                sessionsLine: list.liveSessions.map { SessionSummary.tooltip($0) },
                activeNumber: active?.number, accounts: accounts,
                themes: themes, nextRecovery: panelRecovery, sessions: sessions, error: nil))
        } catch {
            emitError("engine error: \(error)")
        }
    }

    static func emitPanel(_ payload: PanelPayload) {
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: rotate / switch

    static func switchTo(_ arg: String?) async {
        guard let arg, let n = Int(arg) else { fail("usage: infinitus-tray switch <n>") }
        guard let bin = CswapLocator.locate() else { fail("cswap not found") }
        do {
            _ = try await CswapCLI(binaryPath: bin).switchTo(n)
            print("switched to \(n)")
        } catch {
            fail("switch failed: \(error)")
        }
    }

    static func setRotation(_ arg: String?, enabled: Bool) async {
        let verb = enabled ? "enable" : "disable"
        guard let arg, let n = Int(arg) else { fail("usage: infinitus-tray \(verb) <n>") }
        guard let bin = CswapLocator.locate() else { fail("cswap not found") }
        do {
            _ = try await CswapCLI(binaryPath: bin).setRotation(n, enabled: enabled)
            print("\(verb)d \(n)")
        } catch {
            fail("\(verb) failed: \(error)")
        }
    }

    static func rotate() async {
        guard let bin = CswapLocator.locate() else { fail("cswap not found") }
        do {
            _ = try await CswapCLI(binaryPath: bin).rotate()
            print("rotated")
        } catch {
            fail("rotate failed: \(error)")
        }
    }

    // MARK: plumbing

    /// Waybar tooltips are pango markup — escape the payload wholesale.
    static func pango(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func emit(_ payload: WaybarPayload) {
        let escaped = WaybarPayload(text: pango(payload.text),
                                    tooltip: pango(payload.tooltip),
                                    class: payload.class,
                                    percentage: payload.percentage)
        let data = (try? JSONEncoder().encode(escaped)) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
