import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Settings › Lock (spec §2.2). `LockPolicy` is the core state machine;
/// this pane persists it via `WinLockStore`. Windows Hello is omitted —
/// LocalAuthentication has no counterpart here, so turning the lock on
/// arms the policy without a biometric prompt. `.onSleep` is stored but
/// does not fire until a later phase feeds sleep/wake.
public final class LockPane: SettingsPane {
    public static let descriptor = SettingsCatalogWin.lock

    private var ctx: PaneContext?
    private var enableHwnd: HWND?
    private var relockComboHwnd: HWND?
    private var lockNowBtnHwnd: HWND?
    private var statusHwnd: HWND?
    private var relockLabelHwnd: HWND?

    private var policy = LockPolicy()

    private enum Cmd {
        static let enable: Int32 = 1
        static let relock: Int32 = 2
        static let lockNow: Int32 = 3
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase
        enableHwnd = PaneControls.checkbox("Lock the pop-out and this window", in: ctx, id: base + Cmd.enable, x: 0, y: 0, w: 0, h: 0)
        relockLabelHwnd = PaneControls.label("Re-lock", in: ctx, x: 0, y: 0, w: 0, h: 0)
        relockComboHwnd = PaneControls.combo(WinLockStore.relockLabels.map(\.1), in: ctx, id: base + Cmd.relock, x: 0, y: 0, w: 0, h: 0)
        lockNowBtnHwnd = PaneControls.button("Lock Now", in: ctx, id: base + Cmd.lockNow, x: 0, y: 0, w: 0, h: 0)
        statusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let fullW = max(100, width - pad * 2)

        var y = pad
        y = PaneControls.sectionHeader("Unlocking", in: ctx, y: y, width: width)
        if let h = enableHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(8)
        if let l = relockLabelHwnd { MoveWindow(l, pad, y + m.px(3), m.labelColumn, fieldH, true) }
        if let c = relockComboHwnd { MoveWindow(c, pad + m.labelColumn + m.px(8), y, m.px(200), m.px(140), true) }
        y += fieldH + m.px(8)
        if let h = lockNowBtnHwnd { MoveWindow(h, pad, y, m.px(110), btnH, true) }
        y += btnH + m.px(8)
        if let h = statusHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(22)
        let help = "Windows Hello is not wired — turning this on locks the surfaces without a biometric prompt (the Mac asks Touch ID / Face ID / password first). A timed re-lock settles on the next interaction; nothing ticks while idle. Sleep/wake are not hooked, so “When the PC sleeps” is stored but does not fire yet. Teams need this on: creating a team, accepting an invite and requesting to join stay unavailable until it is."
        y += PaneControls.helpText(help, in: ctx, x: pad, y: y, width: fullW) + pad
        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 280 }
        return ctx.metrics.px(280)
    }

    public func activate() {
        policy = WinLockStore.load()
        policy.activity(at: Int(Date().timeIntervalSince1970))
        persist()
        paint()
    }

    public func deactivate() {
        policy.hidden()
        persist()
    }

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.enable:
            toggle(PaneControls.checked(enableHwnd))
            return true
        case Cmd.relock:
            if code == UINT(CBN_SELCHANGE) {
                let sel = PaneControls.comboSelection(relockComboHwnd)
                if let pair = WinLockStore.relockLabels.first(where: { $0.1 == sel }) {
                    policy.relock = pair.0
                    persist()
                }
            }
            return true
        case Cmd.lockNow:
            policy.lock()
            persist()
            paint()
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { WinDark.drawButton(item) }

    private func toggle(_ on: Bool) {
        if on {
            policy.setEnabled(true)
            policy.unlocked(at: Int(Date().timeIntervalSince1970))
            persist()
            paint()
            return
        }
        let teams = WinLockStore.teamNames()
        if !teams.isEmpty {
            let joined = teams.joined(separator: ", ")
            let title = Array("Turn off lock?".utf16) + [0]
            let msg = Array("You're in \(joined). Team data stays on this PC and re-locks only behind the identity prompt on each launch; you stay in the team.".utf16) + [0]
            let ok = title.withUnsafeBufferPointer { tb in
                msg.withUnsafeBufferPointer { mb in
                    MessageBoxW(ctx?.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
                }
            }
            if !ok {
                PaneControls.setChecked(enableHwnd, true)
                return
            }
        }
        policy.setEnabled(false)
        persist()
        paint()
    }

    private func persist() {
        try? WinLockStore.save(policy)
    }

    private func paint() {
        PaneControls.setChecked(enableHwnd, policy.enabled)
        let label = WinLockStore.relockLabels.first { $0.0 == policy.relock }?.1 ?? LockPolicy.Relock.default.label
        PaneControls.setComboSelection(relockComboHwnd, label)
        PaneControls.enable(relockComboHwnd, policy.enabled)
        PaneControls.enable(lockNowBtnHwnd, policy.enabled)
        let status: String
        if !policy.enabled {
            status = "Off"
        } else if policy.locked {
            status = "Locked — re-lock \(policy.relock.label)"
        } else {
            status = "Unlocked — re-lock \(policy.relock.label)"
        }
        PaneControls.setText(statusHwnd, status)
    }
}
