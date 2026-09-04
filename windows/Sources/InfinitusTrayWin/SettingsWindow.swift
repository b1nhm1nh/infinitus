import Foundation
import InfinitusCore
import WinSDK

/// Win32 Settings dialog matching macOS SettingsPane and EnginesPane.
/// Provides configuration for:
/// 1. System & Tray (Start with Windows)
/// 2. Cswap Auto-switch policy (threshold, strategy, cooldown, interval, hysteresis)
/// 3. Cswap UI Theme
/// 4. 9Router Engine (Base URL, Password, Test connection, Open Dashboard)
public enum SettingsWindow {
    private static let windowClassName = "InfinitusSettingsWindow"
    private nonisolated(unsafe) static var isClassRegistered = false
    private nonisolated(unsafe) static var openHwnd: HWND?

    // Command IDs
    private static let saveButtonId: Int32 = 2001
    private static let cancelButtonId: Int32 = 2002
    private static let reloadButtonId: Int32 = 2003

    // System
    private static let autostartCheckId: Int32 = 2101

    // Cswap Auto-switch
    private static let thresholdEditId: Int32 = 2201
    private static let intervalEditId: Int32 = 2202
    private static let cooldownEditId: Int32 = 2203
    private static let hysteresisEditId: Int32 = 2204
    private static let strategyComboId: Int32 = 2205
    private static let includeApiKeyCheckId: Int32 = 2206
    private static let unhealthyTicksEditId: Int32 = 2207
    private static let themeComboId: Int32 = 2208

    // 9Router Engine (matching Mac EnginesPane)
    private static let nineRouterBaseURLEditId: Int32 = 2301
    private static let nineRouterPasswordEditId: Int32 = 2302
    private static let nineRouterTestButtonId: Int32 = 2303
    private static let nineRouterDashboardButtonId: Int32 = 2304

    final class State {
        var hwnd: HWND?
        var font: HFONT?
        var boldFont: HFONT?

        // Control HWNDs
        var autostartHwnd: HWND?
        var thresholdHwnd: HWND?
        var intervalHwnd: HWND?
        var cooldownHwnd: HWND?
        var hysteresisHwnd: HWND?
        var strategyHwnd: HWND?
        var includeApiKeyHwnd: HWND?
        var unhealthyTicksHwnd: HWND?
        var themeHwnd: HWND?

        // 9Router HWNDs
        var nineRouterBaseURLHwnd: HWND?
        var nineRouterPasswordHwnd: HWND?
        var nineRouterTestHwnd: HWND?
        var nineRouterDashboardHwnd: HWND?
        var nineRouterStatusHwnd: HWND?

        var statusLabelHwnd: HWND?

        // Original cswap config key -> value
        var originalValues: [String: String] = [:]

        deinit {
            if let font { DeleteObject(font) }
            if let boldFont { DeleteObject(boldFont) }
        }
    }

    /// Persistent 9Router settings file path on Windows ($APPDATA/Infinitus/9router.json)
    private static var nineRouterConfigPath: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("9router.json")
    }

    private struct NineRouterStoredConfig: Codable {
        var baseURL: String
        var password: String
    }

    /// Shows or brings existing Settings window to foreground.
    public static func show() {
        if let existing = openHwnd, IsWindow(existing) {
            if IsIconic(existing) { ShowWindow(existing, SW_RESTORE) }
            SetForegroundWindow(existing)
            return
        }

        registerClassIfNeeded()

        let state = State()
        let title = "Infinitus Settings"
        let titleWide = Array(title.utf16) + [0]
        let classWide = Array(windowClassName.utf16) + [0]
        let instance = GetModuleHandleW(nil)

        let statePtr = Unmanaged.passRetained(state).toOpaque()

        let width: Int32 = 500
        let height: Int32 = 680

        let screenW = GetSystemMetrics(SM_CXSCREEN)
        let screenH = GetSystemMetrics(SM_CYSCREEN)
        let x = (screenW - width) / 2
        let y = (screenH - height) / 2

        let style = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_CLIPCHILDREN) | DWORD(WS_VISIBLE)
        let hwnd = CreateWindowExW(
            DWORD(WS_EX_DLGMODALFRAME | WS_EX_TOPMOST),
            classWide,
            titleWide,
            style,
            x, y, width, height,
            nil, nil, instance, statePtr
        )

        guard let hwnd else {
            _ = Unmanaged<State>.fromOpaque(statePtr).takeRetainedValue()
            return
        }

        state.hwnd = hwnd
        openHwnd = hwnd
        ShowWindow(hwnd, SW_SHOW)
        UpdateWindow(hwnd)
        SetForegroundWindow(hwnd)

        loadValues(state: state)
    }

    private static func registerClassIfNeeded() {
        guard !isClassRegistered else { return }
        let classWide = Array(windowClassName.utf16) + [0]
        let instance = GetModuleHandleW(nil)

        var wc = WNDCLASSW()
        wc.lpfnWndProc = settingsWndProc
        wc.hInstance = instance
        wc.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        classWide.withUnsafeBufferPointer { buf in
            wc.lpszClassName = buf.baseAddress
            _ = RegisterClassW(&wc)
        }
        isClassRegistered = true
    }

    private static let settingsWndProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = {
        hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }

        if msg == UINT(WM_NCCREATE) {
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))
            if let ptr = cs?.pointee.lpCreateParams {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }

        let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard raw != 0, let ptr = UnsafeMutableRawPointer(bitPattern: Int(raw)) else {
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        let state = Unmanaged<State>.fromOpaque(ptr).takeUnretainedValue()

        switch Int32(bitPattern: msg) {
        case WM_CREATE:
            onCreate(hwnd: hwnd, state: state)
            return 0

        case WM_COMMAND:
            let cmdId = Int32(wParam & 0xFFFF)
            let code = UINT((wParam >> 16) & 0xFFFF)
            if code == UINT(BN_CLICKED) {
                switch cmdId {
                case saveButtonId:
                    saveValues(state: state)
                    DestroyWindow(hwnd)
                case cancelButtonId:
                    DestroyWindow(hwnd)
                case reloadButtonId:
                    loadValues(state: state)
                case nineRouterTestButtonId:
                    testNineRouterConnection(state: state)
                case nineRouterDashboardButtonId:
                    openNineRouterDashboard(state: state)
                default:
                    break
                }
            }
            return 0

        case WM_DESTROY:
            openHwnd = nil
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            Unmanaged<State>.fromOpaque(ptr).release()
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }

    private static func onCreate(hwnd: HWND, state: State) {
        let instance = GetModuleHandleW(nil)

        state.font = CreateFontW(
            -12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
            DWORD(DEFAULT_CHARSET),
            DWORD(OUT_DEFAULT_PRECIS),
            DWORD(CLIP_DEFAULT_PRECIS),
            DWORD(CLEARTYPE_QUALITY),
            DWORD(DEFAULT_PITCH | FF_DONTCARE),
            Array("Segoe UI".utf16) + [0]
        )
        state.boldFont = CreateFontW(
            -12, 0, 0, 0, FW_BOLD, 0, 0, 0,
            DWORD(DEFAULT_CHARSET),
            DWORD(OUT_DEFAULT_PRECIS),
            DWORD(CLIP_DEFAULT_PRECIS),
            DWORD(CLEARTYPE_QUALITY),
            DWORD(DEFAULT_PITCH | FF_DONTCARE),
            Array("Segoe UI".utf16) + [0]
        )

        let staticClass = Array("STATIC".utf16) + [0]
        let buttonClass = Array("BUTTON".utf16) + [0]
        let editClass = Array("EDIT".utf16) + [0]
        let comboClass = Array("COMBOBOX".utf16) + [0]

        func addLabel(_ text: String, x: Int32, y: Int32, w: Int32, h: Int32, bold: Bool = false) {
            let labelHwnd = CreateWindowExW(
                0, staticClass, Array(text.utf16) + [0],
                DWORD(WS_CHILD | WS_VISIBLE | SS_LEFT),
                x, y, w, h, hwnd, nil, instance, nil
            )
            SendMessageW(labelHwnd, UINT(WM_SETFONT),
                         WPARAM(UInt(bitPattern: bold ? state.boldFont : state.font)), LPARAM(1))
        }

        var y: Int32 = 12

        // SECTION: System / Windows
        addLabel("System & Tray", x: 20, y: y, w: 440, h: 18, bold: true)
        y += 20

        state.autostartHwnd = CreateWindowExW(
            0, buttonClass, Array("Start Infinitus Tray with Windows".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP),
            20, y, 320, 20, hwnd, HMENU(bitPattern: Int(autostartCheckId)), instance, nil
        )
        SendMessageW(state.autostartHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 28

        // SECTION: Cswap Engine / Auto-switch Policy
        addLabel("Engine Policy (cswap auto-switch)", x: 20, y: y, w: 440, h: 18, bold: true)
        y += 20

        // Threshold %
        addLabel("Switch Threshold (%):", x: 20, y: y + 3, w: 160, h: 18)
        state.thresholdHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 80, 22, hwnd, HMENU(bitPattern: Int(thresholdEditId)), instance, nil
        )
        SendMessageW(state.thresholdHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        addLabel("50–99.9 (default: 90)", x: 290, y: y + 3, w: 170, h: 18)
        y += 26

        // Strategy
        addLabel("Switch Strategy:", x: 20, y: y + 3, w: 160, h: 18)
        state.strategyHwnd = CreateWindowExW(
            0, comboClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_TABSTOP),
            200, y, 160, 120, hwnd, HMENU(bitPattern: Int(strategyComboId)), instance, nil
        )
        SendMessageW(state.strategyHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        for strategy in ["best", "consume-first"] {
            let strWide = Array(strategy.utf16) + [0]
            SendMessageW(state.strategyHwnd, UINT(CB_ADDSTRING), 0,
                         LPARAM(UInt(bitPattern: strWide.withUnsafeBufferPointer { $0.baseAddress })))
        }
        y += 26

        // Interval seconds
        addLabel("Interval (seconds):", x: 20, y: y + 3, w: 160, h: 18)
        state.intervalHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 80, 22, hwnd, HMENU(bitPattern: Int(intervalEditId)), instance, nil
        )
        SendMessageW(state.intervalHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        addLabel("Scan cycle (default: 60)", x: 290, y: y + 3, w: 170, h: 18)
        y += 26

        // Cooldown seconds
        addLabel("Cooldown (seconds):", x: 20, y: y + 3, w: 160, h: 18)
        state.cooldownHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 80, 22, hwnd, HMENU(bitPattern: Int(cooldownEditId)), instance, nil
        )
        SendMessageW(state.cooldownHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        addLabel("Switch gap (default: 300)", x: 290, y: y + 3, w: 170, h: 18)
        y += 26

        // Hysteresis %
        addLabel("Hysteresis (%):", x: 20, y: y + 3, w: 160, h: 18)
        state.hysteresisHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 80, 22, hwnd, HMENU(bitPattern: Int(hysteresisEditId)), instance, nil
        )
        SendMessageW(state.hysteresisHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        addLabel("Anti-flap margin (10)", x: 290, y: y + 3, w: 170, h: 18)
        y += 26

        // Unhealthy ticks
        addLabel("Unhealthy Ticks:", x: 20, y: y + 3, w: 160, h: 18)
        state.unhealthyTicksHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 80, 22, hwnd, HMENU(bitPattern: Int(unhealthyTicksEditId)), instance, nil
        )
        SendMessageW(state.unhealthyTicksHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        addLabel("Ticks before dead (3)", x: 290, y: y + 3, w: 170, h: 18)
        y += 26

        // Include API key accounts
        state.includeApiKeyHwnd = CreateWindowExW(
            0, buttonClass, Array("Include API key accounts in auto-switch".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP),
            200, y, 260, 20, hwnd, HMENU(bitPattern: Int(includeApiKeyCheckId)), instance, nil
        )
        SendMessageW(state.includeApiKeyHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 28

        // SECTION: Interface Theme
        addLabel("CLI Theme:", x: 20, y: y + 3, w: 160, h: 18)
        state.themeHwnd = CreateWindowExW(
            0, comboClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_TABSTOP),
            200, y, 160, 120, hwnd, HMENU(bitPattern: Int(themeComboId)), instance, nil
        )
        SendMessageW(state.themeHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        for theme in ["auto", "dark", "light"] {
            let themeWide = Array(theme.utf16) + [0]
            SendMessageW(state.themeHwnd, UINT(CB_ADDSTRING), 0,
                         LPARAM(UInt(bitPattern: themeWide.withUnsafeBufferPointer { $0.baseAddress })))
        }
        y += 32

        // SECTION: 9Router Provider (Mac EnginesPane parity)
        addLabel("9Router Provider Engine", x: 20, y: y, w: 440, h: 18, bold: true)
        y += 20

        addLabel("Dashboard URL:", x: 20, y: y + 3, w: 160, h: 18)
        state.nineRouterBaseURLHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 260, 22, hwnd, HMENU(bitPattern: Int(nineRouterBaseURLEditId)), instance, nil
        )
        SendMessageW(state.nineRouterBaseURLHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 26

        addLabel("Dashboard Password:", x: 20, y: y + 3, w: 160, h: 18)
        state.nineRouterPasswordHwnd = CreateWindowExW(
            DWORD(WS_EX_CLIENTEDGE), editClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | ES_PASSWORD | ES_AUTOHSCROLL | WS_TABSTOP),
            200, y, 260, 22, hwnd, HMENU(bitPattern: Int(nineRouterPasswordEditId)), instance, nil
        )
        SendMessageW(state.nineRouterPasswordHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 28

        state.nineRouterTestHwnd = CreateWindowExW(
            0, buttonClass, Array("Test connection".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_TABSTOP),
            200, y, 120, 24, hwnd, HMENU(bitPattern: Int(nineRouterTestButtonId)), instance, nil
        )
        SendMessageW(state.nineRouterTestHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        state.nineRouterDashboardHwnd = CreateWindowExW(
            0, buttonClass, Array("Open Dashboard".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_TABSTOP),
            330, y, 130, 24, hwnd, HMENU(bitPattern: Int(nineRouterDashboardButtonId)), instance, nil
        )
        SendMessageW(state.nineRouterDashboardHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 26

        state.nineRouterStatusHwnd = CreateWindowExW(
            0, staticClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | SS_LEFT),
            200, y, 280, 36, hwnd, nil, instance, nil
        )
        SendMessageW(state.nineRouterStatusHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 40

        // Status / warning label
        state.statusLabelHwnd = CreateWindowExW(
            0, staticClass, nil,
            DWORD(WS_CHILD | WS_VISIBLE | SS_LEFT),
            20, y, 460, 36, hwnd, nil, instance, nil
        )
        SendMessageW(state.statusLabelHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
        y += 38

        // Buttons: Save, Cancel, Reload
        let saveHwnd = CreateWindowExW(
            0, buttonClass, Array("Save".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON | WS_TABSTOP),
            200, y, 80, 26, hwnd, HMENU(bitPattern: Int(saveButtonId)), instance, nil
        )
        SendMessageW(saveHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        let cancelHwnd = CreateWindowExW(
            0, buttonClass, Array("Cancel".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_TABSTOP),
            290, y, 80, 26, hwnd, HMENU(bitPattern: Int(cancelButtonId)), instance, nil
        )
        SendMessageW(cancelHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))

        let reloadHwnd = CreateWindowExW(
            0, buttonClass, Array("Reload".utf16) + [0],
            DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_TABSTOP),
            380, y, 80, 26, hwnd, HMENU(bitPattern: Int(reloadButtonId)), instance, nil
        )
        SendMessageW(reloadHwnd, UINT(WM_SETFONT),
                     WPARAM(UInt(bitPattern: state.font)), LPARAM(1))
    }

    private static func setEditText(_ hwnd: HWND?, _ text: String) {
        guard let hwnd else { return }
        let wide = Array(text.utf16) + [0]
        wide.withUnsafeBufferPointer { buf in
            SendMessageW(hwnd, UINT(WM_SETTEXT), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
    }

    private static func getEditText(_ hwnd: HWND?) -> String {
        guard let hwnd else { return "" }
        let len = SendMessageW(hwnd, UINT(WM_GETTEXTLENGTH), 0, 0)
        guard len > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(len) + 1)
        buffer.withUnsafeMutableBufferPointer { buf in
            SendMessageW(hwnd, UINT(WM_GETTEXT), WPARAM(buf.count), LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    private static func setComboSelected(_ hwnd: HWND?, _ text: String) {
        guard let hwnd else { return }
        let wide = Array(text.utf16) + [0]
        let idx = wide.withUnsafeBufferPointer { buf in
            SendMessageW(hwnd, UINT(CB_FINDSTRINGEXACT), WPARAM(bitPattern: -1), LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
        if idx != CB_ERR {
            SendMessageW(hwnd, UINT(CB_SETCURSEL), WPARAM(idx), 0)
        }
    }

    private static func getComboSelected(_ hwnd: HWND?) -> String {
        guard let hwnd else { return "" }
        let idx = SendMessageW(hwnd, UINT(CB_GETCURSEL), 0, 0)
        guard idx != CB_ERR else { return "" }
        let len = SendMessageW(hwnd, UINT(CB_GETLBTEXTLEN), WPARAM(idx), 0)
        guard len > 0 else { return "" }
        var buffer = [WCHAR](repeating: 0, count: Int(len) + 1)
        buffer.withUnsafeMutableBufferPointer { buf in
            SendMessageW(hwnd, UINT(CB_GETLBTEXT), WPARAM(idx), LPARAM(UInt(bitPattern: buf.baseAddress)))
        }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    private static func setCheckState(_ hwnd: HWND?, _ checked: Bool) {
        guard let hwnd else { return }
        SendMessageW(hwnd, UINT(BM_SETCHECK), WPARAM(checked ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private static func getCheckState(_ hwnd: HWND?) -> Bool {
        guard let hwnd else { return false }
        return SendMessageW(hwnd, UINT(BM_GETCHECK), 0, 0) == BST_CHECKED
    }

    /// Read cswap config and 9Router config.
    private static func loadValues(state: State) {
        setCheckState(state.autostartHwnd, TrayAutostart.isEnabled())

        // Load 9Router settings
        var nineRouterURL = NineRouterEngine.defaultBaseURL.absoluteString
        var nineRouterPass = ""
        if let data = try? Data(contentsOf: nineRouterConfigPath),
           let stored = try? JSONDecoder().decode(NineRouterStoredConfig.self, from: data) {
            nineRouterURL = stored.baseURL
            nineRouterPass = stored.password
        } else if let routed = ClaudeCodeRouting.anthropicBaseURL() {
            // Default to Claude Code's routed origin if configured
            if let origin = ClaudeCodeRouting.origin(of: routed) {
                nineRouterURL = origin.absoluteString
            }
        }
        setEditText(state.nineRouterBaseURLHwnd, nineRouterURL)
        setEditText(state.nineRouterPasswordHwnd, nineRouterPass)
        setEditText(state.nineRouterStatusHwnd, "")

        guard let binary = CswapLocator.locate() else {
            setEditText(state.statusLabelHwnd, "cswap engine not found on system")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["config", "list", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            setEditText(state.statusLabelHwnd, "Failed to run cswap")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let config = try? JSONDecoder().decode(ConfigList.self, from: data)
        else {
            setEditText(state.statusLabelHwnd, "Unable to read cswap settings")
            return
        }

        state.originalValues = [:]
        for entry in config.settings {
            let strVal: String
            switch entry.value {
            case .string(let s): strVal = s
            case .number(let n): strVal = n == n.rounded() ? String(Int(n)) : String(n)
            case .bool(let b): strVal = b ? "true" : "false"
            case .null: strVal = ""
            default: strVal = ""
            }
            state.originalValues[entry.key] = strVal

            switch entry.key {
            case "autoswitch.threshold":
                setEditText(state.thresholdHwnd, strVal.isEmpty ? "90" : strVal)
            case "autoswitch.strategy":
                setComboSelected(state.strategyHwnd, strVal.isEmpty ? "best" : strVal)
            case "autoswitch.intervalSeconds":
                setEditText(state.intervalHwnd, strVal.isEmpty ? "60" : strVal)
            case "autoswitch.cooldownSeconds":
                setEditText(state.cooldownHwnd, strVal.isEmpty ? "300" : strVal)
            case "autoswitch.hysteresisPct":
                setEditText(state.hysteresisHwnd, strVal.isEmpty ? "10" : strVal)
            case "autoswitch.unhealthyTicks":
                setEditText(state.unhealthyTicksHwnd, strVal.isEmpty ? "3" : strVal)
            case "autoswitch.includeApiKeyAccounts":
                setCheckState(state.includeApiKeyHwnd, strVal == "true")
            case "ui.theme":
                setComboSelected(state.themeHwnd, strVal.isEmpty ? "auto" : strVal)
            default:
                break
            }
        }

        setEditText(state.statusLabelHwnd, "Settings loaded.")
    }

    /// Save dirty values via `cswap config set` and persist 9Router config.
    private static func saveValues(state: State) {
        // Autostart
        let autostartDesired = getCheckState(state.autostartHwnd)
        if autostartDesired != TrayAutostart.isEnabled() {
            TrayAutostart.setEnabled(autostartDesired)
        }

        // 9Router save
        let nrURL = getEditText(state.nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
        let nrPass = getEditText(state.nineRouterPasswordHwnd).trimmingCharacters(in: .whitespaces)
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
        targetValues["autoswitch.threshold"] = getEditText(state.thresholdHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.strategy"] = getComboSelected(state.strategyHwnd)
        targetValues["autoswitch.intervalSeconds"] = getEditText(state.intervalHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.cooldownSeconds"] = getEditText(state.cooldownHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.hysteresisPct"] = getEditText(state.hysteresisHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.unhealthyTicks"] = getEditText(state.unhealthyTicksHwnd).trimmingCharacters(in: .whitespaces)
        targetValues["autoswitch.includeApiKeyAccounts"] = getCheckState(state.includeApiKeyHwnd) ? "true" : "false"
        targetValues["ui.theme"] = getComboSelected(state.themeHwnd)

        for (key, newVal) in targetValues {
            let oldVal = state.originalValues[key] ?? ""
            if newVal != oldVal, !newVal.isEmpty {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binary)
                p.arguments = ["config", "set", key, newVal]
                try? p.run()
                p.waitUntilExit()
            }
        }
    }

    /// Test 9Router connection asynchronously (matching Mac test() method).
    private static func testNineRouterConnection(state: State) {
        let urlText = getEditText(state.nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
        let passText = getEditText(state.nineRouterPasswordHwnd).trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: urlText.isEmpty ? NineRouterEngine.defaultBaseURL.absoluteString : urlText) else {
            setEditText(state.nineRouterStatusHwnd, "Invalid URL")
            return
        }
        setEditText(state.nineRouterStatusHwnd, "Testing connection…")

        Thread.detachNewThread {
            let engine = NineRouterEngine(baseURL: url, password: passText)
            Task {
                do {
                    let probe = try await engine.probe()
                    let msg = "Reachable — \(probe.connections) connections (\(probe.claudeConnections) Claude)"
                    DispatchQueue.global().async {
                        setEditText(state.nineRouterStatusHwnd, msg)
                    }
                } catch {
                    let err = (error as? EngineError)?.errorDescription ?? "\(error)"
                    DispatchQueue.global().async {
                        setEditText(state.nineRouterStatusHwnd, err)
                    }
                }
            }
        }
    }

    /// Open 9Router dashboard in default browser.
    private static func openNineRouterDashboard(state: State) {
        var urlText = getEditText(state.nineRouterBaseURLHwnd).trimmingCharacters(in: .whitespaces)
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
