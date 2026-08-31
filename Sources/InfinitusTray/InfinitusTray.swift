import Foundation
import CswapCore

// The Omarchy/Linux face of Infinitus: a Waybar `custom` module
// (`return-type: json`) over the same CswapCore the macOS app uses.
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

@main
struct InfinitusTray {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "status" : args.removeFirst()
        var themeID = "off"
        var remaining = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--theme" where i + 1 < args.count:
                themeID = args[i + 1]
                i += 1
            case "--remaining":
                remaining = true
            default:
                fail("unknown option: \(args[i])")
            }
            i += 1
        }
        switch command {
        case "status":
            await status(themeID: themeID, remaining: remaining)
        case "rotate":
            await rotate()
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
      rotate                              switch to the next account
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
            let list = try await CswapCLI(binaryPath: bin).accountList()
            let now = Date()
            let active = list.accounts.first { $0.active }
            let prefs = TitlePrefs(showAccountName: true, titlePct: "both",
                                   titleScoped: false, titleRemaining: remaining)
            let rows = list.accounts.map { row($0, list: list, theme: theme, now: now) }
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
    static func row(_ a: Account, list: AccountList, theme: RowTheme, now: Date) -> String {
        let name = a.alias ?? String(a.email.prefix(while: { $0 != "@" }))
        let marker: String
        if a.active { marker = theme.activeIcon.isEmpty ? "●" : theme.activeIcon }
        else if a.number == list.nextCandidate { marker = theme.nextIcon.isEmpty ? "▶" : theme.nextIcon }
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

    // MARK: rotate

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
