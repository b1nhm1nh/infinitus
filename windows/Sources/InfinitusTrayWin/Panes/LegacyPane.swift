import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Temporary "Legacy" pane hosting the previous four controls from SettingsWindow:
/// 1. Autostart checkbox
/// 2. Cswap auto-switch keys (threshold, strategy, interval, cooldown, hysteresis, unhealthy ticks, include-api-key)
/// 3. ui.theme combo
/// 4. 9Router base URL, password, test button, open dashboard button
/// 5. Save, Cancel, Reload buttons
public final class LegacyPane: SettingsPane {
    public static let descriptor = PaneDescriptor(
        id: "legacy",
        title: "Legacy",
        glyph: "L",
        tintRGB: (120, 120, 130),
        keywords: [],
        section: .general
    )

    private var ctx: PaneContext?
    private var autostartHwnd: HWND?
    private var thresholdHwnd: HWND?
    private var intervalHwnd: HWND?
    private var cooldownHwnd: HWND?
    private var hysteresisHwnd: HWND?
    private var strategyHwnd: HWND?
    private var includeApiKeyHwnd: HWND?
    private var unhealthyTicksHwnd: HWND?
    private var themeHwnd: HWND?

    private var nineRouterBaseURLHwnd: HWND?
    private var nineRouterPasswordHwnd: HWND?
    private var nineRouterTestHwnd: HWND?
    private var nineRouterDashboardHwnd: HWND?
    private var nineRouterStatusHwnd: HWND?

    private var statusLabelHwnd: HWND?
    private var saveButtonHwnd: HWND?
    private var cancelButtonHwnd: HWND?
    private var reloadButtonHwnd: HWND?

    private var originalValues: [String: String] = [:]

    // Local command ID offsets relative to ctx.idBase
    private enum Cmd {
        static let save: Int32 = 1
        static let cancel: Int32 = 2
        static let reload: Int32 = 3
        static let autostart: Int32 = 10
        static let threshold: Int32 = 20
        static let interval: Int32 = 21
        static let cooldown: Int32 = 22
        static let hysteresis: Int32 = 23
        static let strategy: Int32 = 24
        static let includeApiKey: Int32 = 25
        static let unhealthyTicks: Int32 = 26
        static let theme: Int32 = 27
        static let nrBaseURL: Int32 = 40
        static let nrPassword: Int32 = 41
        static let nrTest: Int32 = 42
        static let nrDashboard: Int32 = 43
    }

    private struct NineRouterStoredConfig: Codable {
        var baseURL: String
        var password: String
    }

    private var nineRouterConfigPath: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("9router.json")
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase

        // Autostart
        autostartHwnd = PaneControls.checkbox("Start Infinitus Tray with Windows", in: ctx, id: base + Cmd.autostart, x: 0, y: 0, w: 0, h: 0)

        // Cswap controls
        thresholdHwnd = PaneControls.edit(in: ctx, id: base + Cmd.threshold, x: 0, y: 0, w: 0, h: 0)
        strategyHwnd = PaneControls.combo(["best", "consume-first"], in: ctx, id: base + Cmd.strategy, x: 0, y: 0, w: 0, h: 0)
        intervalHwnd = PaneControls.edit(in: ctx, id: base + Cmd.interval, x: 0, y: 0, w: 0, h: 0)
        cooldownHwnd = PaneControls.edit(in: ctx, id: base + Cmd.cooldown, x: 0, y: 0, w: 0, h: 0)
        hysteresisHwnd = PaneControls.edit(in: ctx, id: base + Cmd.hysteresis, x: 0, y: 0, w: 0, h: 0)
        unhealthyTicksHwnd = PaneControls.edit(in: ctx, id: base + Cmd.unhealthyTicks, x: 0, y: 0, w: 0, h: 0)
        includeApiKeyHwnd = PaneControls.checkbox("Auto-switch API key accounts", in: ctx, id: base + Cmd.includeApiKey, x: 0, y: 0, w: 0, h: 0)

        let themeChoices = ["auto", "dark", "light", "catppuccin-mocha", "catppuccin-latte", "nord", "tokyo-night"]
        themeHwnd = PaneControls.combo(themeChoices, in: ctx, id: base + Cmd.theme, x: 0, y: 0, w: 0, h: 0)

        // 9Router controls
        nineRouterBaseURLHwnd = PaneControls.edit(in: ctx, id: base + Cmd.nrBaseURL, x: 0, y: 0, w: 0, h: 0)
        nineRouterPasswordHwnd = PaneControls.edit(in: ctx, id: base + Cmd.nrPassword, x: 0, y: 0, w: 0, h: 0, password: true)
        nineRouterTestHwnd = PaneControls.button("Test connection", in: ctx, id: base + Cmd.nrTest, x: 0, y: 0, w: 0, h: 0)
        nineRouterDashboardHwnd = PaneControls.button("Open Dashboard", in: ctx, id: base + Cmd.nrDashboard, x: 0, y: 0, w: 0, h: 0)
        nineRouterStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        // Status & action buttons
        statusLabelHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        saveButtonHwnd = PaneControls.button("Save", in: ctx, id: base + Cmd.save, x: 0, y: 0, w: 0, h: 0, default_: true)
        cancelButtonHwnd = PaneControls.button("Cancel", in: ctx, id: base + Cmd.cancel, x: 0, y: 0, w: 0, h: 0)
        reloadButtonHwnd = PaneControls.button("Reload", in: ctx, id: base + Cmd.reload, x: 0, y: 0, w: 0, h: 0)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let m = ctx.metrics
        let pad = m.pad
        let colW = m.labelColumn
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let rowGap = m.px(6)

        var y = pad

        // SECTION: System
        y += m.px(24) // header gap
        if let h = autostartHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + rowGap * 2

        // SECTION: Cswap Policy
        y += m.px(24)
        if let h = thresholdHwnd {
            MoveWindow(h, pad + colW, y, m.px(80), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = strategyHwnd {
            MoveWindow(h, pad + colW, y, m.px(160), m.px(120), true)
        }
        y += fieldH + rowGap

        if let h = intervalHwnd {
            MoveWindow(h, pad + colW, y, m.px(80), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = cooldownHwnd {
            MoveWindow(h, pad + colW, y, m.px(80), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = hysteresisHwnd {
            MoveWindow(h, pad + colW, y, m.px(80), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = unhealthyTicksHwnd {
            MoveWindow(h, pad + colW, y, m.px(80), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = includeApiKeyHwnd {
            MoveWindow(h, pad, y, width - pad * 2, fieldH, true)
        }
        y += fieldH + rowGap

        if let h = themeHwnd {
            MoveWindow(h, pad + colW, y, m.px(160), m.px(140), true)
        }
        y += fieldH + rowGap * 2

        // SECTION: 9Router
        y += m.px(24)
        if let h = nineRouterBaseURLHwnd {
            MoveWindow(h, pad + colW, y, min(m.px(300), width - pad * 2 - colW), fieldH, true)
        }
        y += fieldH + rowGap

        if let h = nineRouterPasswordHwnd {
            MoveWindow(h, pad + colW, y, min(m.px(300), width - pad * 2 - colW), fieldH, true)
        }
        y += fieldH + rowGap

        if let t = nineRouterTestHwnd, let d = nineRouterDashboardHwnd {
            MoveWindow(t, pad + colW, y, m.px(120), btnH, true)
            MoveWindow(d, pad + colW + m.px(130), y, m.px(140), btnH, true)
        }
        y += btnH + rowGap

        if let h = nineRouterStatusHwnd {
            MoveWindow(h, pad + colW, y, width - pad * 2 - colW, m.px(36), true)
        }
        y += m.px(40)

        // Status & actions
        if let h = statusLabelHwnd {
            MoveWindow(h, pad, y, width - pad * 2, m.px(30), true)
        }
        y += m.px(34)

        if let s = saveButtonHwnd, let c = cancelButtonHwnd, let r = reloadButtonHwnd {
            MoveWindow(s, pad, y, m.px(80), btnH, true)
            MoveWindow(c, pad + m.px(90), y, m.px(80), btnH, true)
            MoveWindow(r, pad + m.px(180), y, m.px(80), btnH, true)
        }
        y += btnH + pad

        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 650 }
        return ctx.metrics.px(650)
    }

    public func activate() {
        loadValues()
    }

    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.save:
            saveValues()
            return true
        case Cmd.cancel:
            PostMessageW(ctx.shell, UINT(WM_CLOSE), 0, 0)
            return true
        case Cmd.reload:
            loadValues()
            return true
        case Cmd.nrTest:
            testNineRouter()
            return true
        case Cmd.nrDashboard:
            openDashboard()
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }

    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool {
        WinDark.drawButton(item)
    }

    private func loadValues() {
        PaneControls.setChecked(autostartHwnd, TrayAutostart.isEnabled())

        var nrURL = NineRouterEngine.defaultBaseURL.absoluteString
        var nrPass = ""
        if let data = try? Data(contentsOf: nineRouterConfigPath),
           let stored = try? JSONDecoder().decode(NineRouterStoredConfig.self, from: data) {
            nrURL = stored.baseURL
            nrPass = stored.password
        } else if let routed = ClaudeCodeRouting.anthropicBaseURL() {
            if let origin = ClaudeCodeRouting.origin(of: routed) {
                nrURL = origin.absoluteString
            }
        }
        PaneControls.setText(nineRouterBaseURLHwnd, nrURL)
        PaneControls.setText(nineRouterPasswordHwnd, nrPass)
        PaneControls.setText(nineRouterStatusHwnd, "")

        guard let binary = CswapLocator.locate() else {
            PaneControls.setText(statusLabelHwnd, "cswap engine not found on system")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["config", "list", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            PaneControls.setText(statusLabelHwnd, "Failed to run cswap")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let config = try? JSONDecoder().decode(ConfigList.self, from: data)
        else {
            PaneControls.setText(statusLabelHwnd, "Unable to read cswap settings")
            return
        }

        originalValues = [:]
        for entry in config.settings {
            let strVal: String
            switch entry.value {
            case .string(let s): strVal = s
            case .number(let n): strVal = n == n.rounded() ? String(Int(n)) : String(n)
            case .bool(let b): strVal = b ? "true" : "false"
            default: strVal = ""
            }
            originalValues[entry.key] = strVal

            switch entry.key {
            case "autoswitch.threshold":
                PaneControls.setText(thresholdHwnd, strVal.isEmpty ? "90" : strVal)
            case "autoswitch.strategy":
                PaneControls.setComboSelection(strategyHwnd, strVal.isEmpty ? "best" : strVal)
            case "autoswitch.intervalSeconds":
                PaneControls.setText(intervalHwnd, strVal.isEmpty ? "60" : strVal)
            case "autoswitch.cooldownSeconds":
                PaneControls.setText(cooldownHwnd, strVal.isEmpty ? "300" : strVal)
            case "autoswitch.hysteresisPct":
                PaneControls.setText(hysteresisHwnd, strVal.isEmpty ? "10" : strVal)
            case "autoswitch.unhealthyTicks":
                PaneControls.setText(unhealthyTicksHwnd, strVal.isEmpty ? "3" : strVal)
            case "autoswitch.includeApiKeyAccounts":
                PaneControls.setChecked(includeApiKeyHwnd, strVal == "true")
            case "ui.theme":
                PaneControls.setComboSelection(themeHwnd, strVal.isEmpty ? "auto" : strVal)
            default:
                break
            }
        }
        PaneControls.setText(statusLabelHwnd, "Settings loaded.")
    }

    private func saveValues() {
        let autostartDesired = PaneControls.checked(autostartHwnd)
        if autostartDesired != TrayAutostart.isEnabled() {
            TrayAutostart.setEnabled(autostartDesired)
        }

        let nrURL = PaneControls.text(nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
        let nrPass = PaneControls.text(nineRouterPasswordHwnd).trimmingCharacters(in: .whitespaces)
        let nrConfig = NineRouterStoredConfig(
            baseURL: nrURL.isEmpty ? NineRouterEngine.defaultBaseURL.absoluteString : nrURL,
            password: nrPass
        )
        if let encoded = try? JSONEncoder().encode(nrConfig) {
            try? FileManager.default.createDirectory(at: nineRouterConfigPath.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? encoded.write(to: nineRouterConfigPath)
        }

        guard let binary = CswapLocator.locate() else { return }

        var targetValues: [String: String] = [:]
        targetValues["autoswitch.threshold"] = PaneControls.text(thresholdHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.strategy"] = PaneControls.comboSelection(strategyHwnd)
        targetValues["autoswitch.intervalSeconds"] = PaneControls.text(intervalHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.cooldownSeconds"] = PaneControls.text(cooldownHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.hysteresisPct"] = PaneControls.text(hysteresisHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.unhealthyTicks"] = PaneControls.text(unhealthyTicksHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.includeApiKeyAccounts"] = PaneControls.checked(includeApiKeyHwnd) ? "true" : "false"
        targetValues["ui.theme"] = PaneControls.comboSelection(themeHwnd)

        for (key, newVal) in targetValues {
            let oldVal = originalValues[key] ?? ""
            if newVal != oldVal, !newVal.isEmpty {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["config", "set", key, newVal]
                try? p.run()
                p.waitUntilExit()
            }
        }
        PaneControls.setText(statusLabelHwnd, "Saved.")
    }

    private func testNineRouter() {
        guard let ctx else { return }
        let urlText = PaneControls.text(nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
        let passText = PaneControls.text(nineRouterPasswordHwnd).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText.isEmpty ? NineRouterEngine.defaultBaseURL.absoluteString : urlText) else {
            PaneControls.setText(nineRouterStatusHwnd, "Invalid URL")
            return
        }
        PaneControls.setText(nineRouterStatusHwnd, "Testing connection…")

        ctx.async({
            let engine = NineRouterEngine(baseURL: url, password: passText)
            let sema = DispatchSemaphore(value: 0)
            var msg = ""
            Task {
                do {
                    let probe = try await engine.probe()
                    msg = "Reachable — \(probe.connections) connections (\(probe.claudeConnections) Claude)"
                } catch {
                    let err = (error as? EngineError)?.errorDescription ?? "\(error)"
                    msg = err
                }
                sema.signal()
            }
            sema.wait()
            return msg
        }, then: { [weak self] resultText in
            self?.applyTestResult(resultText)
        })
    }

    private func applyTestResult(_ text: String) {
        PaneControls.setText(nineRouterStatusHwnd, text)
    }

    private func openDashboard() {
        var urlText = PaneControls.text(nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
        if urlText.isEmpty {
            urlText = NineRouterEngine.defaultBaseURL.absoluteString
        }
        if !urlText.hasSuffix("/dashboard") {
            urlText = urlText.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/dashboard"
        }
        let urlWide = Array(urlText.utf16) + [0]
        let openWide = Array("open".utf16) + [0]
        _ = urlWide.withUnsafeBufferPointer { urlBuf in
            openWide.withUnsafeBufferPointer { opBuf in
                ShellExecuteW(nil, opBuf.baseAddress, urlBuf.baseAddress, nil, nil, SW_SHOWNORMAL)
            }
        }
    }
}
