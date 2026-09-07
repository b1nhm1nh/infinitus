import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Settings › Profiles (#165): named ways to start a session. Same
/// `SessionProfile` / `SessionProfiles` core types the Mac pane drives.
public final class ProfilesPane: SettingsPane {
    public static let descriptor = SettingsCatalogWin.profiles

    private var ctx: PaneContext?

    private var listComboHwnd: HWND?
    private var summaryHwnd: HWND?
    private var cwdEditHwnd: HWND?
    private var engineComboHwnd: HWND?
    private var permissionComboHwnd: HWND?
    private var modelEditHwnd: HWND?
    private var systemPromptEditHwnd: HWND?
    private var promptEditHwnd: HWND?
    private var allowEditHwnd: HWND?
    private var removeBtnHwnd: HWND?
    private var newNameEditHwnd: HWND?
    private var addBtnHwnd: HWND?
    private var errorHwnd: HWND?

    private var cwdLabelHwnd: HWND?
    private var engineLabelHwnd: HWND?
    private var permissionLabelHwnd: HWND?
    private var modelLabelHwnd: HWND?
    private var systemLabelHwnd: HWND?
    private var promptLabelHwnd: HWND?
    private var allowLabelHwnd: HWND?

    private var profiles: [SessionProfile] = []
    private var selectedName: String?
    private var lastError: String?

    private let engineLabels = ["Claude Code", "Codex CLI"]
    private let engineKeys = ["claude", "codex"]
    private let permissionLabels: [String] = ["Supervised"] + SessionStart.permissionModes.map(\.label)
    private let permissionKeys: [String] = [""] + SessionStart.permissionModes.map(\.mode)

    private enum Cmd {
        static let list: Int32 = 1
        static let engine: Int32 = 2
        static let permission: Int32 = 3
        static let remove: Int32 = 4
        static let add: Int32 = 5
        static let cwd: Int32 = 10
        static let model: Int32 = 11
        static let system: Int32 = 12
        static let prompt: Int32 = 13
        static let allow: Int32 = 14
        static let newName: Int32 = 15
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        listComboHwnd = PaneControls.combo([], in: ctx, id: base + Cmd.list, x: 0, y: 0, w: 0, h: 0)
        summaryHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.dim)

        cwdLabelHwnd = PaneControls.label("Folder", in: ctx, x: 0, y: 0, w: 0, h: 0)
        cwdEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.cwd, x: 0, y: 0, w: 0, h: 0)

        engineLabelHwnd = PaneControls.label("Engine", in: ctx, x: 0, y: 0, w: 0, h: 0)
        engineComboHwnd = PaneControls.combo(engineLabels, in: ctx, id: base + Cmd.engine, x: 0, y: 0, w: 0, h: 0)

        permissionLabelHwnd = PaneControls.label("Permissions", in: ctx, x: 0, y: 0, w: 0, h: 0)
        permissionComboHwnd = PaneControls.combo(permissionLabels, in: ctx, id: base + Cmd.permission, x: 0, y: 0, w: 0, h: 0)

        modelLabelHwnd = PaneControls.label("Model", in: ctx, x: 0, y: 0, w: 0, h: 0)
        modelEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.model, x: 0, y: 0, w: 0, h: 0)

        systemLabelHwnd = PaneControls.label("Appended system prompt", in: ctx, x: 0, y: 0, w: 0, h: 0)
        systemPromptEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.system, x: 0, y: 0, w: 0, h: 0, multiline: true)

        promptLabelHwnd = PaneControls.label("First prompt", in: ctx, x: 0, y: 0, w: 0, h: 0)
        promptEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.prompt, x: 0, y: 0, w: 0, h: 0, multiline: true)

        allowLabelHwnd = PaneControls.label("Allowed without asking", in: ctx, x: 0, y: 0, w: 0, h: 0)
        allowEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.allow, x: 0, y: 0, w: 0, h: 0)

        removeBtnHwnd = PaneControls.button("Remove…", in: ctx, id: base + Cmd.remove, x: 0, y: 0, w: 0, h: 0)

        newNameEditHwnd = PaneControls.edit(in: ctx, id: base + Cmd.newName, x: 0, y: 0, w: 0, h: 0)
        addBtnHwnd = PaneControls.button("Add", in: ctx, id: base + Cmd.add, x: 0, y: 0, w: 0, h: 0)
        errorHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true, color: WinDark.destructive)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let colW = m.labelColumn
        let fullW = max(100, width - pad * 2)
        let fieldW = max(80, fullW - colW - m.px(8))

        var y = pad
        y = PaneControls.sectionHeader("Profiles", in: ctx, y: y, width: width)
        if let h = listComboHwnd { MoveWindow(h, pad, y, fullW, m.px(140), true) }
        y += fieldH + m.px(6)
        if let h = summaryHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(22) + m.px(8)

        func row(_ label: HWND?, _ field: HWND?, fieldH: Int32 = fieldH) {
            if let label { MoveWindow(label, pad, y + m.px(3), colW, fieldH, true) }
            if let field { MoveWindow(field, pad + colW + m.px(8), y, fieldW, fieldH, true) }
        }

        row(cwdLabelHwnd, cwdEditHwnd)
        y += fieldH + m.px(6)
        row(engineLabelHwnd, engineComboHwnd)
        y += fieldH + m.px(6)
        row(permissionLabelHwnd, permissionComboHwnd)
        y += fieldH + m.px(6)
        row(modelLabelHwnd, modelEditHwnd)
        y += fieldH + m.px(8)
        row(systemLabelHwnd, systemPromptEditHwnd, fieldH: m.px(56))
        y += m.px(60)
        row(promptLabelHwnd, promptEditHwnd, fieldH: m.px(44))
        y += m.px(48)
        row(allowLabelHwnd, allowEditHwnd)
        y += fieldH + m.px(8)
        if let h = removeBtnHwnd { MoveWindow(h, pad, y, m.px(110), btnH, true) }
        y += btnH + m.sectionGap

        y = PaneControls.sectionHeader("New profile", in: ctx, y: y, width: width)
        if let e = newNameEditHwnd { MoveWindow(e, pad, y, fullW - m.px(90), fieldH, true) }
        if let b = addBtnHwnd { MoveWindow(b, pad + fullW - m.px(80), y, m.px(80), btnH, true) }
        y += btnH + m.px(6)
        if let h = errorHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(22)
        let help = "A profile is a named way to start a session — folder, engine, permissions, model, an appended system prompt and a first prompt. The phone offers each one as a chip in Start a session."
        y += PaneControls.helpText(help, in: ctx, x: pad, y: y, width: fullW) + pad
        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 520 }
        return ctx.metrics.px(520)
    }

    public func activate() {
        reload()
        paint()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.list:
            if code == UINT(CBN_SELCHANGE) {
                selectedName = PaneControls.comboSelection(listComboHwnd)
                paintFields()
            }
            return true
        case Cmd.engine, Cmd.permission:
            if code == UINT(CBN_SELCHANGE) { commitFields() }
            return true
        case Cmd.cwd, Cmd.model, Cmd.system, Cmd.prompt, Cmd.allow:
            if code == UINT(EN_KILLFOCUS) { commitFields() }
            return true
        case Cmd.remove:
            confirmRemove()
            return true
        case Cmd.add:
            addProfile()
            return true
        case Cmd.newName:
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { WinDark.drawButton(item) }

    private func reload() {
        profiles = WinProfilesStore.load()
        if selectedName == nil { selectedName = profiles.first?.name }
        if let name = selectedName, !profiles.contains(where: { SessionProfiles.same($0.name, name) }) {
            selectedName = profiles.first?.name
        }
    }

    private func paint() {
        rebuildCombo()
        paintFields()
        PaneControls.setText(errorHwnd, lastError ?? "")
        let has = selectedName != nil
        PaneControls.enable(cwdEditHwnd, has)
        PaneControls.enable(engineComboHwnd, has)
        PaneControls.enable(permissionComboHwnd, has)
        PaneControls.enable(modelEditHwnd, has)
        PaneControls.enable(systemPromptEditHwnd, has)
        PaneControls.enable(promptEditHwnd, has)
        PaneControls.enable(allowEditHwnd, has)
        PaneControls.enable(removeBtnHwnd, has)
    }

    private func rebuildCombo() {
        guard let hwnd = listComboHwnd else { return }
        SendMessageW(hwnd, UINT(CB_RESETCONTENT), 0, 0)
        for p in profiles {
            let wide = Array(p.name.utf16) + [0]
            _ = wide.withUnsafeBufferPointer { buf in
                SendMessageW(hwnd, UINT(CB_ADDSTRING), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
            }
        }
        if let name = selectedName {
            PaneControls.setComboSelection(hwnd, name)
        }
    }

    private func selected() -> SessionProfile? {
        guard let name = selectedName else { return nil }
        return profiles.first { SessionProfiles.same($0.name, name) }
    }

    private func paintFields() {
        guard let p = selected() else {
            PaneControls.setText(summaryHwnd, profiles.isEmpty ? "No profiles yet." : "")
            PaneControls.setText(cwdEditHwnd, "")
            PaneControls.setText(modelEditHwnd, "")
            PaneControls.setText(systemPromptEditHwnd, "")
            PaneControls.setText(promptEditHwnd, "")
            PaneControls.setText(allowEditHwnd, "")
            return
        }
        PaneControls.setText(summaryHwnd, p.summary)
        PaneControls.setText(cwdEditHwnd, p.cwd ?? "")
        let engineKey = p.engine ?? "claude"
        let engineLabel = engineKeys.firstIndex(of: engineKey).map { engineLabels[$0] } ?? engineLabels[0]
        PaneControls.setComboSelection(engineComboHwnd, engineLabel)
        let permKey = p.permissionMode ?? ""
        let permLabel = permissionKeys.firstIndex(of: permKey).map { permissionLabels[$0] } ?? permissionLabels[0]
        PaneControls.setComboSelection(permissionComboHwnd, permLabel)
        PaneControls.setText(modelEditHwnd, p.model ?? "")
        PaneControls.setText(systemPromptEditHwnd, p.systemPrompt ?? "")
        PaneControls.setText(promptEditHwnd, p.prompt ?? "")
        PaneControls.setText(allowEditHwnd, (p.allowTools ?? []).joined(separator: ", "))
    }

    private func commitFields() {
        guard var next = selected() else { return }
        next.cwd = PaneControls.text(cwdEditHwnd)
        let engineSel = PaneControls.comboSelection(engineComboHwnd)
        next.engine = engineLabels.firstIndex(of: engineSel).map { engineKeys[$0] }
        let permSel = PaneControls.comboSelection(permissionComboHwnd)
        next.permissionMode = permissionLabels.firstIndex(of: permSel).map { permissionKeys[$0] }
        next.model = PaneControls.text(modelEditHwnd)
        next.systemPrompt = PaneControls.text(systemPromptEditHwnd)
        next.prompt = PaneControls.text(promptEditHwnd)
        next.allowTools = SessionProfiles.parseAllowList(PaneControls.text(allowEditHwnd))
        write(SessionProfiles.upsert(next, into: profiles))
    }

    private func addProfile() {
        let name = PaneControls.text(newNameEditHwnd).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        write(SessionProfiles.upsert(SessionProfile(name: name), into: profiles))
        selectedName = name
        PaneControls.setText(newNameEditHwnd, "")
        paint()
    }

    private func confirmRemove() {
        guard let p = selected(), let ctx else { return }
        let title = Array("Remove \(p.name)?".utf16) + [0]
        let msg = Array("Start a session stops offering \(p.name) on the phone and on this PC. Sessions already started keep running — you can make the profile again any time.".utf16) + [0]
        let ok = title.withUnsafeBufferPointer { tb in
            msg.withUnsafeBufferPointer { mb in
                MessageBoxW(ctx.shell, mb.baseAddress, tb.baseAddress, UINT(MB_YESNO | MB_ICONWARNING)) == IDYES
            }
        }
        guard ok else { return }
        write(SessionProfiles.removing(p.name, from: profiles))
        selectedName = profiles.first?.name
        paint()
    }

    private func write(_ next: [SessionProfile]) {
        do {
            try WinProfilesStore.save(next)
            profiles = next
            lastError = nil
        } catch {
            lastError = "couldn't save profiles: \(error.localizedDescription)"
        }
        PaneControls.setText(errorHwnd, lastError ?? "")
        if let p = selected() { PaneControls.setText(summaryHwnd, p.summary) }
    }
}
