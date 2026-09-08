import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Settings › Machine (#115). Numbers from InfinitusCore
/// (`MachineReport`, `HookInventory`, `Runaways`, `Residue`,
/// `SessionHealth`); process listing is `WinMachineSampler`. No timer —
/// sample on activate and Sample Now. Darwin-only actions (`lsof` temp
/// reclaim, SIGTERM process-group kill) are omitted, not shown dead.
public final class MachinePane: SettingsPane {
    public static let descriptor = SettingsCatalogWin.machine

    private var ctx: PaneContext?
    private var watchHwnd: HWND?
    private var notifyHooksHwnd: HWND?
    private var notifyTempHwnd: HWND?
    private var sampleBtnHwnd: HWND?
    private var sampledHwnd: HWND?
    private var resultHwnd: HWND?
    private var idleComboHwnd: HWND?
    private var idleLabelHwnd: HWND?
    private var reclaimBtnHwnd: HWND?

    private var prefs = WinMachineStore.Prefs()
    private var report: MachineReport?
    private var parked: [String] = []
    private var lastSampledAt: Date?
    private var resultMessage: String?
    private var sampling = false
    private var computedHeight: Int32 = 700

    private var hookOwners: [String] = []
    private var runawayPids: [Int] = []

    private enum Cmd {
        static let watch: Int32 = 1
        static let notifyHooks: Int32 = 2
        static let notifyTemp: Int32 = 3
        static let sample: Int32 = 4
        static let reclaim: Int32 = 5
        static let idle: Int32 = 6
        static let disableBase: Int32 = 100
        static let restoreBase: Int32 = 200
        static let runawayBase: Int32 = 300
    }

    private let idleChoices = [1, 4, 8, 12, 24, 48, 72]

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase
        watchHwnd = PaneControls.checkbox("Watch this PC", in: ctx, id: base + Cmd.watch, x: 0, y: 0, w: 0, h: 0)
        notifyHooksHwnd = PaneControls.checkbox("Notify about hooks (new, stuck, fanned out)", in: ctx, id: base + Cmd.notifyHooks, x: 0, y: 0, w: 0, h: 0)
        notifyTempHwnd = PaneControls.checkbox("Notify about the temp directory", in: ctx, id: base + Cmd.notifyTemp, x: 0, y: 0, w: 0, h: 0)
        sampleBtnHwnd = PaneControls.button("Sample Now", in: ctx, id: base + Cmd.sample, x: 0, y: 0, w: 0, h: 0)
        sampledHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        resultHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
        idleLabelHwnd = PaneControls.label("Notify when a session is idle for", in: ctx, x: 0, y: 0, w: 0, h: 0)
        idleComboHwnd = PaneControls.combo(idleChoices.map { "\($0) h" }, in: ctx, id: base + Cmd.idle, x: 0, y: 0, w: 0, h: 0)
        reclaimBtnHwnd = PaneControls.button("Reclaim…", in: ctx, id: base + Cmd.reclaim, x: 0, y: 0, w: 0, h: 0)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        hookOwners = []
        runawayPids = []
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let fullW = max(100, width - pad * 2)
        let base = ctx.idBase

        var y = pad
        y = PaneControls.sectionHeader("Watching", in: ctx, y: y, width: width)
        if let h = watchHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(4)
        if let h = notifyHooksHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(4)
        if let h = notifyTempHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(8)
        if let h = sampleBtnHwnd { MoveWindow(h, pad, y, m.px(120), btnH, true) }
        if let h = sampledHwnd { MoveWindow(h, pad + m.px(130), y + m.px(4), fullW - m.px(130), fieldH, true) }
        y += btnH + m.px(4)
        if let h = resultHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(20)
        y += PaneControls.helpText("Watching costs one process listing a minute on the Mac; here it samples only when this pane opens or you click Sample Now. Load average and WindowServer CPU are Darwin-only and omitted.", in: ctx, x: pad, y: y, width: fullW)
        y += m.sectionGap

        y = PaneControls.sectionHeader("Summary", in: ctx, y: y, width: width)
        if let report {
            for (label, value) in WinMachineText.summaryLines(report.sample) {
                _ = PaneControls.label("\(label):  \(value)", in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, transient: true)
                y += m.px(20)
            }
        } else {
            _ = PaneControls.label("No sample yet", in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.dim, transient: true)
            y += m.px(20)
        }
        y += m.sectionGap

        y = PaneControls.sectionHeader("Warnings", in: ctx, y: y, width: width)
        let warnings = report?.warnings ?? []
        if warnings.isEmpty {
            _ = PaneControls.label("Nothing to flag", in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.dim, transient: true)
            y += m.px(20)
        } else {
            for w in warnings {
                _ = PaneControls.label(w, in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.warmTint, transient: true)
                y += m.px(20)
            }
        }
        y += m.sectionGap

        y = PaneControls.sectionHeader("Hooks", in: ctx, y: y, width: width)
        if let report {
            let groups = WinMachineText.hookGroups(report)
            if groups.isEmpty {
                _ = PaneControls.label("No hook registrations", in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.dim, transient: true)
                y += m.px(20)
            } else {
                for (i, g) in groups.enumerated() {
                    hookOwners.append(g.owner)
                    _ = PaneControls.label(WinMachineText.hookLines(report)[i], in: ctx, x: pad, y: y, w: fullW - m.px(110), h: m.px(32), caption: true, transient: true)
                    if g.kind == .plugin {
                        _ = PaneControls.label("Managed by Claude Code", in: ctx, x: pad + fullW - m.px(160), y: y, w: m.px(160), h: m.px(18), caption: true, color: WinDark.dim, transient: true)
                    } else if parked.contains(g.owner) {
                        let btn = PaneControls.button("Restore", in: ctx, id: base + Cmd.restoreBase + Int32(i), x: pad + fullW - m.px(90), y: y, w: m.px(90), h: btnH)
                        ctx.registerTransient(btn)
                    } else {
                        let btn = PaneControls.button("Disable…", in: ctx, id: base + Cmd.disableBase + Int32(i), x: pad + fullW - m.px(90), y: y, w: m.px(90), h: btnH)
                        ctx.registerTransient(btn)
                    }
                    y += m.px(36)
                }
            }
        }
        y += m.sectionGap

        y = PaneControls.sectionHeader("Runaways", in: ctx, y: y, width: width)
        if let report {
            if report.runaways.isEmpty {
                _ = PaneControls.label("Nothing flagged", in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.dim, transient: true)
                y += m.px(20)
            } else {
                for (i, r) in report.runaways.enumerated() {
                    runawayPids.append(r.pid)
                    _ = PaneControls.label(WinMachineText.runawayLines(report)[i], in: ctx, x: pad, y: y, w: fullW - m.px(90), h: m.px(32), caption: true, transient: true)
                    let btn = PaneControls.button("Kill…", in: ctx, id: base + Cmd.runawayBase + Int32(i), x: pad + fullW - m.px(80), y: y, w: m.px(80), h: btnH)
                    ctx.registerTransient(btn)
                    y += m.px(36)
                }
            }
        }
        y += m.sectionGap

        y = PaneControls.sectionHeader("Residue", in: ctx, y: y, width: width)
        if let r = report?.residue {
            _ = PaneControls.label(WinMachineText.residueLine(r), in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, transient: true)
            y += m.px(20)
            _ = PaneControls.label(WinMachineText.residueSizes(r), in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, color: WinDark.dim, transient: true)
            y += m.px(22)
        }
        if let h = reclaimBtnHwnd { MoveWindow(h, pad, y, m.px(110), btnH, true) }
        y += btnH + m.px(6)
        y += PaneControls.helpText("Temp-file reclaim is omitted: the Mac uses lsof to skip files still held open, and Windows has no equivalent here.", in: ctx, x: pad, y: y, width: fullW)
        y += m.sectionGap

        y = PaneControls.sectionHeader("Sessions", in: ctx, y: y, width: width)
        if let l = idleLabelHwnd { MoveWindow(l, pad, y + m.px(3), m.px(240), fieldH, true) }
        if let c = idleComboHwnd { MoveWindow(c, pad + m.px(248), y, m.px(80), m.px(140), true) }
        y += fieldH + m.px(8)
        for line in WinMachineText.sessionLines(report?.sessions ?? []) {
            _ = PaneControls.label(line, in: ctx, x: pad, y: y, w: fullW, h: m.px(18), caption: true, transient: true)
            y += m.px(20)
        }
        y += pad
        computedHeight = y
        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 { computedHeight }

    public func activate() {
        prefs = WinMachineStore.load()
        paintPrefs()
        if prefs.enabled { runSample() }
        else { relayout() }
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.watch:
            prefs.enabled = PaneControls.checked(watchHwnd)
            persistPrefs()
            return true
        case Cmd.notifyHooks:
            prefs.notifyHooks = PaneControls.checked(notifyHooksHwnd)
            persistPrefs()
            return true
        case Cmd.notifyTemp:
            prefs.notifyTemp = PaneControls.checked(notifyTempHwnd)
            persistPrefs()
            return true
        case Cmd.sample:
            runSample()
            return true
        case Cmd.reclaim:
            confirmReclaim()
            return true
        case Cmd.idle:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(idleComboHwnd)
                if let hours = Int(sel.split(separator: " ").first.map(String.init) ?? "") {
                    prefs.idleHours = Double(hours)
                    persistPrefs()
                }
            }
            return true
        default:
            break
        }
        if rel >= Cmd.disableBase, rel < Cmd.restoreBase {
            let i = Int(rel - Cmd.disableBase)
            if i >= 0, i < hookOwners.count { confirmDisable(hookOwners[i]) }
            return true
        }
        if rel >= Cmd.restoreBase, rel < Cmd.runawayBase {
            let i = Int(rel - Cmd.restoreBase)
            if i >= 0, i < hookOwners.count { restore(hookOwners[i]) }
            return true
        }
        if rel >= Cmd.runawayBase {
            let i = Int(rel - Cmd.runawayBase)
            if i >= 0, i < runawayPids.count { confirmKill(runawayPids[i]) }
            return true
        }
        return false
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { WinDark.drawButton(item) }

    private func paintPrefs() {
        PaneControls.setChecked(watchHwnd, prefs.enabled)
        PaneControls.setChecked(notifyHooksHwnd, prefs.notifyHooks)
        PaneControls.setChecked(notifyTempHwnd, prefs.notifyTemp)
        let hours = Int(prefs.idleHours)
        let nearest = idleChoices.min(by: { abs($0 - hours) < abs($1 - hours) }) ?? 12
        PaneControls.setComboSelection(idleComboHwnd, "\(nearest) h")
        PaneControls.setText(resultHwnd, resultMessage ?? "")
        if let at = lastSampledAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm:ss"
            PaneControls.setText(sampledHwnd, "Sampled \(f.string(from: at))")
        }
        PaneControls.enable(sampleBtnHwnd, !sampling)
    }

    private func persistPrefs() {
        try? WinMachineStore.save(prefs)
    }

    private func runSample() {
        guard !sampling, let ctx else { return }
        sampling = true
        resultMessage = nil
        paintPrefs()
        let snapshot = prefs
        ctx.async({
            WinMachineStore.sample(prefs: snapshot)
        }, then: { [weak self] result in
            guard let self else { return }
            self.sampling = false
            self.report = result.report
            self.prefs = result.prefs
            self.parked = result.parked
            self.lastSampledAt = Date()
            self.persistPrefs()
            self.paintPrefs()
            self.relayout()
        })
    }

    private func relayout() {
        guard let ctx, let host = Optional(ctx.host) else { return }
        var rc = RECT()
        GetClientRect(host, &rc)
        layout(width: rc.right - rc.left, height: rc.bottom - rc.top)
        InvalidateRect(host, nil, true)
    }

    private func confirmDisable(_ owner: String) {
        let title = Array("Disable \(owner) hooks?".utf16) + [0]
        let msg = Array("Move \(owner)'s hook registrations out of ~/.claude/settings.json? A backup is written beside it.".utf16) + [0]
        let ok = title.withUnsafeBufferPointer { tb in
            msg.withUnsafeBufferPointer { mb in
                MessageBoxW(ctx?.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
            }
        }
        guard ok, let ctx else { return }
        ctx.async({ WinMachineStore.disableHook(owner: owner) }, then: { [weak self] text in
            self?.resultMessage = text
            self?.runSample()
        })
    }

    private func restore(_ owner: String) {
        ctx?.async({ WinMachineStore.restoreHook(owner: owner) }, then: { [weak self] text in
            self?.resultMessage = text
            self?.runSample()
        })
    }

    private func confirmKill(_ pid: Int) {
        let title = Array("Kill pid \(pid)?".utf16) + [0]
        let msg = Array("Terminate pid \(pid)? The Mac sends SIGTERM then SIGKILL to the process group; here it is TerminateProcess on that pid only.".utf16) + [0]
        let ok = title.withUnsafeBufferPointer { tb in
            msg.withUnsafeBufferPointer { mb in
                MessageBoxW(ctx?.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
            }
        }
        guard ok, let ctx else { return }
        ctx.async({ WinMachineStore.terminate(pid: pid) }, then: { [weak self] text in
            self?.resultMessage = text
            self?.runSample()
        })
    }

    private func confirmReclaim() {
        let residue = report?.residue
        let title = Array("Reclaim residue?".utf16) + [0]
        let msg = Array("\(residue?.staleSockets ?? 0) stale sockets, \(residue?.staleSessionEnvs ?? 0) session-env dirs. Temp files are not touched (no lsof).".utf16) + [0]
        let ok = title.withUnsafeBufferPointer { tb in
            msg.withUnsafeBufferPointer { mb in
                MessageBoxW(ctx?.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
            }
        }
        guard ok, let ctx else { return }
        ctx.async({ WinMachineStore.reclaim() }, then: { [weak self] text in
            self?.resultMessage = text
            self?.runSample()
        })
    }
}
