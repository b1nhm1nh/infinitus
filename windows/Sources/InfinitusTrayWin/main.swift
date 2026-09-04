// infinitus-tray-win — the notification-area companion to the mirror
// daemon. It shows what this box's Claude Code sessions are doing, and
// gets you to them: click a session to raise its terminal, copy the
// pairing URL for the phone, start or stop `infinitus-win serve`.
//
// Deliberately NOT a port of the Mac app: AppKit/SwiftUI don't exist
// here, so there is no shared view code — only InfinitusCore underneath.
// Accounts and usage stay out of this window; when a swap engine is
// installed the phone and `infinitus-win snapshot` already show them.
import Foundation
import InfinitusCore
import WinSDK

/// Tray callback message (WM_APP+1) and the menu command id base.
let trayMessage = UINT(WM_APP) + 1
let commandBase: UINT = 0x1000
/// Fixed command ids, above any session row.
let commandCopyPair: UINT = 0x0F01
let commandToggleServe: UINT = 0x0F02
let commandRefresh: UINT = 0x0F03
let commandExit: UINT = 0x0F04
let commandAutostart: UINT = 0x0F05
/// Re-read sessions this often. Every tick tails transcripts, so this is
/// the one knob that decides idle cost (CLAUDE.md: keep it near zero).
let refreshMilliseconds: UINT = 5000

/// One row in the menu: what the session is and how to reach it.
struct SessionRow {
    let pid: Int32
    let name: String
    let status: String
    let folder: String
}

/// Everything the window procedure needs. A single instance lives for the
/// process; Win32 callbacks are C function pointers, so it can't be
/// captured — hence a global rather than an object graph.
final class TrayState {
    var window: HWND?
    var icon: HICON?
    var rows: [SessionRow] = []
    var busy = 0
    /// Last tick's pid → status, so a balloon fires on a real change and
    /// not on every refresh. Empty until the first refresh has run.
    var lastStatuses: [Int32: String] = [:]
    /// The `infinitus-win serve` child, when this tray started one. A
    /// daemon someone else started is not ours to stop.
    var daemon: Process?

    var serving: Bool { daemon?.isRunning == true }
}

let state = TrayState()

// MARK: - session reading

/// The live sessions, newest status first. Pure InfinitusCore: the same
/// records the daemon serves, so the tray can never disagree with the
/// phone about what is running.
func readSessions() -> ([SessionRow], busy: Int) {
    let claudeDir = ClaudeSessions.configHome()
    let records = ClaudeSessions.list(claudeDir: claudeDir)
    var rows: [SessionRow] = []
    var busy = 0
    for record in records {
        let status = record.status ?? "unknown"
        if status == "busy" { busy += 1 }
        let progress = SessionProgress.read(sessionId: record.sessionId, cwd: record.cwd,
                                            claudeDir: claudeDir, name: record.name)
        let folder = URL(fileURLWithPath: record.cwd).lastPathComponent
        rows.append(SessionRow(pid: record.pid,
                               name: progress.name ?? record.name ?? "session \(record.pid)",
                               status: status, folder: folder))
    }
    // Busy first, then waiting, then the rest — the Mac's panel order.
    let rank = { (status: String) -> Int in
        switch status {
        case "busy": return 0
        case "waiting": return 1
        default: return 2
        }
    }
    rows.sort { rank($0.status) < rank($1.status) }
    return (rows, busy)
}

// MARK: - raising a session's terminal

/// Brings the window of the process that owns `pid` to the front, walking
/// up to its console host when the session itself owns none. Returns
/// false when there is nothing to raise — the caller stays silent rather
/// than claiming it worked.
func raiseWindow(pid: Int32) -> Bool {
    final class Search {
        let wanted: DWORD
        var found: HWND?
        init(wanted: DWORD) { self.wanted = wanted }
    }
    let search = Search(wanted: DWORD(UInt32(bitPattern: pid)))
    let callback: @convention(c) (HWND?, LPARAM) -> WindowsBool = { window, param in
        guard let window, IsWindowVisible(window) else { return true }
        guard let raw = UnsafeMutableRawPointer(bitPattern: Int(param)) else { return false }
        let search = Unmanaged<Search>.fromOpaque(raw).takeUnretainedValue()
        var owner: DWORD = 0
        GetWindowThreadProcessId(window, &owner)
        guard owner == search.wanted else { return true }
        search.found = window
        return false
    }
    let pointer = Unmanaged.passUnretained(search).toOpaque()
    EnumWindows(callback, LPARAM(Int(bitPattern: pointer)))
    guard let window = search.found else { return false }
    if IsIconic(window) { ShowWindow(window, SW_RESTORE) }
    return SetForegroundWindow(window)
}

// MARK: - the daemon child

/// Starts `infinitus-win serve` beside this binary. The tray only ever
/// stops a daemon it started itself.
func startDaemon() {
    guard state.daemon?.isRunning != true else { return }
    let binary = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("infinitus-win.exe")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["serve"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    state.daemon = process
}

func stopDaemon() {
    guard let daemon = state.daemon, daemon.isRunning else { return }
    daemon.terminate()
    state.daemon = nil
}

// MARK: - tray icon plumbing

func notifyData(_ window: HWND, tip: String? = nil) -> NOTIFYICONDATAW {
    var data = NOTIFYICONDATAW()
    data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
    data.hWnd = window
    data.uID = 1
    data.uFlags = UINT(NIF_ICON | NIF_MESSAGE | NIF_TIP)
    data.uCallbackMessage = trayMessage
    data.hIcon = state.icon
    if let tip {
        // szTip is a fixed 128-WCHAR tuple; fill it through a buffer.
        withUnsafeMutableBytes(of: &data.szTip) { raw in
            let slot = raw.bindMemory(to: WCHAR.self)
            let text = Array(tip.utf16.prefix(slot.count - 1)) + [0]
            for (index, unit) in text.enumerated() { slot[index] = unit }
        }
    }
    return data
}

/// Re-reads sessions, then repaints icon and tooltip.
func refresh() {
    let (rows, busy) = readSessions()
    state.rows = rows
    state.busy = busy
    guard let window = state.window else { return }

    // Announce only what the user would want pulled away for: a session
    // now waiting on them, or one that died mid-turn.
    let statuses = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.status) })
    let names = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.name) })
    for line in TrayNotify.transitions(previous: state.lastStatuses,
                                       current: statuses, names: names) {
        TrayNotify.balloon(window, title: "Infinitus", body: line)
    }
    state.lastStatuses = statuses
    let wasBusy = state.icon != nil && busy > 0
    if let fresh = TrayIcon.make(busy: busy > 0) {
        let previous = state.icon
        state.icon = fresh
        if previous != nil { DestroyIcon(previous) }
        _ = wasBusy
    }
    let tip = busy > 0 ? "\(rows.count) sessions · \(busy) busy"
                       : "\(rows.count) sessions · idle"
    var data = notifyData(window, tip: tip)
    Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
}

/// Right-click menu: a row per session, then the actions.
func showMenu(_ window: HWND) {
    guard let menu = CreatePopupMenu() else { return }
    defer { DestroyMenu(menu) }
    if state.rows.isEmpty {
        AppendMenuW(menu, UINT(MF_STRING | MF_GRAYED), 0, "no live sessions".wide)
    }
    for (index, row) in state.rows.enumerated() {
        let label = "\(row.name) — \(row.status) — \(row.folder)"
        AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandBase + UINT(index)), label.wide)
    }
    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandCopyPair), "Copy pairing URL".wide)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandToggleServe),
                (state.serving ? "Stop mirror daemon" : "Start mirror daemon").wide)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandRefresh), "Refresh".wide)
    let autostart = TrayAutostart.isEnabled()
    AppendMenuW(menu, UINT(MF_STRING | (autostart ? MF_CHECKED : MF_UNCHECKED)),
                UINT_PTR(commandAutostart), "Start with Windows".wide)
    AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(commandExit), "Exit".wide)

    var point = POINT()
    GetCursorPos(&point)
    // Required so the menu dismisses when focus goes elsewhere.
    SetForegroundWindow(window)
    TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
    PostMessageW(window, UINT(WM_NULL), 0, 0)
}

func handleCommand(_ id: UINT) {
    switch id {
    case commandExit:
        DestroyWindow(state.window)
    case commandRefresh:
        refresh()
    case commandCopyPair:
        if let url = WinPairing.pairingURL() { WinPairing.setClipboardText(url) }
    case commandToggleServe:
        state.serving ? stopDaemon() : startDaemon()
    case commandAutostart:
        TrayAutostart.setEnabled(!TrayAutostart.isEnabled())
    default:
        let index = Int(id - commandBase)
        if index >= 0, index < state.rows.count {
            _ = raiseWindow(pid: state.rows[index].pid)
        }
    }
}

// MARK: - window procedure

let windowProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = {
    window, message, wParam, lParam in
    switch Int32(message) {
    case Int32(trayMessage):
        // A right-click (or the keyboard context key) opens the menu; a
        // left-click refreshes so the list is current before you look.
        let event = Int32(lParam & 0xFFFF)
        if event == WM_RBUTTONUP || event == WM_CONTEXTMENU {
            if let window { showMenu(window) }
        } else if event == WM_LBUTTONUP {
            refresh()
            if let window { showMenu(window) }
        }
        return 0
    case WM_COMMAND:
        handleCommand(UINT(wParam & 0xFFFF))
        return 0
    case WM_TIMER:
        refresh()
        return 0
    case WM_DESTROY:
        // Never leave a ghost icon behind.
        if let window {
            var data = notifyData(window)
            Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        }
        stopDaemon()
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}

// MARK: - entry

extension String {
    /// A null-terminated UTF-16 buffer for the W APIs. Valid for the
    /// duration of the call it is passed to.
    var wide: [WCHAR] { Array(utf16) + [0] }
}

func run() -> Int32 {
    // `--probe` reports what the tray can build and exits — the icon and
    // the shell call are invisible from another session, so this is how
    // a failure gets diagnosed without a human watching the taskbar.
    if CommandLine.arguments.dropFirst().first == "--probe" {
        let icon = TrayIcon.make(busy: true)
        print("icon: \(icon == nil ? "FAILED" : "ok")")
        if let icon { DestroyIcon(icon) }
        let (rows, busy) = readSessions()
        print("sessions: \(rows.count) (\(busy) busy)")
        print("pair url: \(WinPairing.pairingURL() ?? "none — run `infinitus-win pair` first")")
        print("autostart: \(TrayAutostart.isEnabled() ? "on" : "off")")
        // The balloon rules, exercised — this decides when the user gets
        // interrupted, and the target can't be unit tested (executables
        // can't be imported by a test target).
        let names: [Int32: String] = [1: "alpha", 2: "beta"]
        let cases: [(String, [Int32: String], [Int32: String], Int)] = [
            ("first tick stays silent", [:], [1: "waiting", 2: "busy"], 0),
            ("idle → waiting announces", [1: "idle"], [1: "waiting"], 1),
            ("busy → idle stays silent", [1: "busy"], [1: "idle"], 0),
            ("still waiting stays silent", [1: "waiting"], [1: "waiting"], 0),
            ("busy → gone announces", [1: "busy"], [:], 1),
            ("idle → gone stays silent", [1: "idle"], [:], 0),
            ("new session already waiting stays silent", [2: "idle"], [1: "waiting", 2: "idle"], 0),
        ]
        var failures = 0
        for (label, previous, current, expected) in cases {
            let lines = TrayNotify.transitions(previous: previous, current: current, names: names)
            let ok = lines.count == expected
            if !ok { failures += 1 }
            print("  [\(ok ? "ok" : "FAIL")] \(label) → \(lines.count) (want \(expected)) \(lines)")
        }
        print("transitions: \(failures == 0 ? "all pass" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }
    let instance = GetModuleHandleW(nil)
    let className = "InfinitusTrayWindow".wide
    var windowClass = WNDCLASSW()
    windowClass.lpfnWndProc = windowProc
    windowClass.hInstance = instance
    windowClass.lpszClassName = UnsafePointer(className)
    guard RegisterClassW(&windowClass) != 0 else { return 1 }

    // A message-only window: no chrome, never shown, just a target for
    // the tray callback and the timer.
    // HWND_MESSAGE isn't exported to Swift; it is the documented
    // message-only parent value (-3).
    let messageOnlyParent = HWND(bitPattern: -3)
    guard let window = CreateWindowExW(0, className, "Infinitus".wide, 0, 0, 0, 0, 0,
                                       messageOnlyParent, nil, instance, nil)
    else { return 1 }
    state.window = window
    state.icon = TrayIcon.make(busy: false)

    let (rows, busy) = readSessions()
    state.rows = rows
    state.busy = busy
    var data = notifyData(window, tip: "\(rows.count) sessions")
    guard Shell_NotifyIconW(DWORD(NIM_ADD), &data) else { return 1 }
    refresh()
    SetTimer(window, 1, refreshMilliseconds, nil)

    var message = MSG()
    // Swift maps GetMessageW's BOOL to Bool: false is WM_QUIT (and the
    // -1 error case, which only a bad HWND produces — ours is ours).
    while GetMessageW(&message, nil, 0, 0) {
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
    if let icon = state.icon { DestroyIcon(icon) }
    return Int32(message.wParam)
}

exit(run())
