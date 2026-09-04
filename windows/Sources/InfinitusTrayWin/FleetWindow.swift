import Foundation
import InfinitusCore
import WinSDK

/// The account panel — the Windows answer to the Mac popup's grid of
/// accounts with 5h/7d gauges (user 2026-09-04: "why windows do not have
/// UI likes MAC?").
///
/// Owner-drawn GDI, because there is no alternative: SwiftUI, AppKit and
/// UIKit ship only inside Apple's SDKs, and the Windows Swift SDK has
/// none of them (verified 2026-09-04 — 25 modules, no SwiftUI). The Mac's
/// 18,478 lines of SwiftUI cannot compile here at all, which is why
/// Package.swift fences them behind `#if os(macOS)`. So every rectangle
/// is placed by hand and every gauge is a FillRect.
///
/// What it deliberately does NOT copy: the burn overlays, HP-drop zooms
/// and intro choreography. Those are CAAnimations on the Mac
/// (CLAUDE.md's hard-won fact: five effects at 20 fps idled the pop-out
/// at 43% CPU; as layer animations, 0.4%). GDI has no equivalent
/// compositor, so imitating them would mean a repaint timer — the exact
/// thing that rule forbids. This paints on demand and on the tray's
/// existing 5 s tick, so an idle panel costs nothing.
///
/// Pace is still SHOWN, just statically: ahead-of-pace tints the bar
/// warm and marks where the burn should be, behind-pace tints it cool.
enum FleetWindow {
    private static let windowClassName = "InfinitusFleetWindow"
    private nonisolated(unsafe) static var isClassRegistered = false
    private nonisolated(unsafe) static var open: HWND?
    /// Own repaint tick, alive only while the window is. 3 s is well
    /// under the engine layer's 30 s cache, so most ticks are a repaint
    /// of unchanged data and the subprocess runs at its own pace.
    private static let refreshTimerId: UINT_PTR = 1
    private static let refreshMilliseconds: UINT = 3000

    // MARK: - metrics (96-dpi reference; scaled per monitor)

    /// Row geometry at 100%. `Metrics` scales these once per paint so the
    /// panel is sharp on a 150% display instead of blurry-stretched.
    struct Metrics {
        let scale: Double
        var pad: Int32 { px(12) }
        var rowHeight: Int32 { px(46) }
        var headerHeight: Int32 { px(30) }
        var footerHeight: Int32 { px(26) }
        var barWidth: Int32 { px(84) }
        var barHeight: Int32 { px(7) }
        var gaugeGap: Int32 { px(14) }
        var numberWidth: Int32 { px(18) }
        var nameWidth: Int32 { px(150) }
        func px(_ value: Int32) -> Int32 { Int32((Double(value) * scale).rounded()) }

        init(hwnd: HWND?) {
            let dpi = hwnd.map { Double(GetDpiForWindow($0)) } ?? 96.0
            scale = max(1.0, dpi / 96.0)
        }
    }

    /// The window's own size for a given panel — computed, not guessed,
    /// so the frame always fits its rows.
    static func idealSize(rows: Int, gauges: Int, metrics: Metrics) -> (width: Int32, height: Int32) {
        let width = metrics.pad * 2 + metrics.numberWidth + metrics.nameWidth
            + Int32(max(1, gauges)) * (metrics.barWidth + metrics.gaugeGap + metrics.px(52))
        let body = Int32(max(1, rows)) * metrics.rowHeight
        let height = metrics.headerHeight + body + metrics.footerHeight + metrics.pad
        return (min(width, metrics.px(980)), min(height, metrics.px(680)))
    }

    // MARK: - colours
    //
    // Dark, like the screenshot. Fixed rather than following the system
    // theme: the Mac popup is dark in both appearances, and a light
    // variant would need its own contrast pass to stay readable.

    private static let bg = RGB(24, 24, 27)
    private static let rowBg = RGB(32, 32, 36)
    private static let activeBg = RGB(30, 58, 95)
    private static let text = RGB(240, 240, 245)
    private static let dim = RGB(150, 150, 160)
    private static let faint = RGB(105, 105, 115)
    private static let track = RGB(58, 58, 64)
    private static let sessionColor = RGB(90, 190, 255)
    private static let weeklyColor = RGB(170, 130, 255)
    private static let scopedColor = RGB(255, 175, 90)
    private static let dangerColor = RGB(255, 95, 95)
    private static let warmTint = RGB(255, 140, 70)
    private static let coolTint = RGB(90, 230, 190)

    private static func RGB(_ r: Int, _ g: Int, _ b: Int) -> COLORREF {
        COLORREF(UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16))
    }

    /// A gauge's colour by its label, matching the Mac's row theme
    /// (session blue, weekly purple, per-model amber) and going red once
    /// the window is spent.
    static func color(for gauge: FleetLayout.Gauge) -> COLORREF {
        if gauge.spent { return dangerColor }
        switch gauge.label {
        case "5h": return sessionColor
        case "7d": return weeklyColor
        default: return scopedColor
        }
    }

    // MARK: - state

    final class State {
        var panel = FleetLayout.Panel(rows: [], activeNumber: nil, footer: "", empty: "Loading\u{2026}")
        var titleFont: HFONT?
        var bodyFont: HFONT?
        var captionFont: HFONT?
        /// Row under the pointer, for the hover highlight.
        var hotRow = -1
        /// Set while a switch is in flight so a second click can't queue
        /// another one behind it.
        var switching = false

        deinit {
            for font in [titleFont, bodyFont, captionFont] {
                if let font { DeleteObject(font) }
            }
        }
    }

    // MARK: - opening

    /// Shows the panel, raising the existing one rather than stacking a
    /// second window (the Mac popup is single too).
    static func show() {
        if let existing = open, IsWindow(existing) {
            if IsIconic(existing) { ShowWindow(existing, SW_RESTORE) }
            SetForegroundWindow(existing)
            refresh(existing)
            return
        }
        registerClassIfNeeded()
        let state = State()
        state.panel = currentPanel()
        let retained = Unmanaged.passRetained(state).toOpaque()

        let title = Array("Infinitus \u{2014} accounts".utf16) + [0]
        let className = Array(windowClassName.utf16) + [0]
        let style = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
        guard let hwnd = CreateWindowExW(
            0, className, title, style,
            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT), 100, 100,
            nil, nil, GetModuleHandleW(nil), retained)
        else {
            Unmanaged<State>.fromOpaque(retained).release()
            return
        }
        open = hwnd
        // Size AFTER creating it, for two reasons found by looking at the
        // result (2026-09-04): GetDpiForWindow needs a real window, so
        // measuring before gave 96 dpi and a panel too small for its own
        // rows; and CreateWindowExW's size is the OUTER frame, so caption
        // and borders were eating the content height — the second row and
        // the footer overlapped.
        resizeToFit(hwnd, panel: state.panel, style: style)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
    }

    /// Grows the window so every row fits, converting the content size to
    /// an outer frame with AdjustWindowRectExForDpi — the client area is
    /// what the painting code addresses, and the frame is what
    /// SetWindowPos takes.
    private static func resizeToFit(_ hwnd: HWND, panel: FleetLayout.Panel, style: DWORD) {
        let metrics = Metrics(hwnd: hwnd)
        let gauges = panel.rows.map(\.gauges.count).max() ?? 2
        let content = idealSize(rows: max(1, panel.rows.count),
                                gauges: gauges, metrics: metrics)
        var rect = RECT(left: 0, top: 0, right: content.width, bottom: content.height)
        AdjustWindowRectExForDpi(&rect, style, false, 0, GetDpiForWindow(hwnd))
        SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    /// Re-reads the engine and repaints — called on the tray's tick so an
    /// open panel stays current without a timer of its own.
    static func refresh(_ hwnd: HWND? = nil) {
        let target = hwnd ?? open
        guard let target, IsWindow(target) else { return }
        let raw = GetWindowLongPtrW(target, GWLP_USERDATA)
        guard raw != 0, let ptr = UnsafeMutableRawPointer(bitPattern: Int(raw)) else { return }
        let state = Unmanaged<State>.fromOpaque(ptr).takeUnretainedValue()
        let previous = state.panel
        state.panel = currentPanel()
        // The first engine read is async, so the panel opens on the
        // "Reading accounts…" placeholder and the rows arrive a moment
        // later. Re-fit when the shape changes or they stay clipped —
        // that is what the first screenshot showed (2026-09-04).
        let rowsChanged = previous.rows.count != state.panel.rows.count
        let gaugesChanged = (previous.rows.map(\.gauges.count).max() ?? 0)
            != (state.panel.rows.map(\.gauges.count).max() ?? 0)
        if rowsChanged || gaugesChanged {
            let style = DWORD(bitPattern: Int32(truncatingIfNeeded:
                GetWindowLongPtrW(target, GWL_STYLE)))
            resizeToFit(target, panel: state.panel, style: style)
        }
        InvalidateRect(target, nil, false)
    }

    /// True while a panel is on screen, so the tray only refreshes then.
    static var isOpen: Bool {
        guard let open else { return false }
        return IsWindow(open)
    }

    private static func currentPanel() -> FleetLayout.Panel {
        // `INFINITUS_ACCOUNTS_JSON=<path>` renders a fixture instead of
        // the engine — the only way to exercise the GAUGE painting here,
        // since a token account reports `usage: null` (usageStatus
        // "unavailable") and draws no bars at all. Same seam the resume
        // supervisor's tests use.
        if let path = ProcessInfo.processInfo.environment["INFINITUS_ACCOUNTS_JSON"],
           !path.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let fixture = try? JSONDecoder().decode(AccountList.self, from: data) {
            let (_, _, live) = liveCounts()
            return FleetLayout.panel(list: fixture, live: live, engineInstalled: true)
        }
        let list = TrayFleet.cached()
        let (_, _, live) = liveCounts()
        return FleetLayout.panel(list: list, live: live,
                                 engineInstalled: TrayFleet.hasEngine())
    }

    /// Session totals for the footer, from the same records the tray
    /// menu counts.
    private static func liveCounts() -> (total: Int, busy: Int, live: LiveSessions) {
        let (rows, busy) = readSessions()
        let waiting = rows.filter { $0.status == "waiting" }.count
        let idle = rows.filter { $0.status == "idle" }.count
        return (rows.count, busy,
                LiveSessions(busy: busy, total: rows.count, idle: idle,
                             waiting: waiting, shell: 0, unknown: 0, sessions: nil))
    }

    private static func registerClassIfNeeded() {
        guard !isClassRegistered else { return }
        let className = Array(windowClassName.utf16) + [0]
        var wc = WNDCLASSW()
        wc.lpfnWndProc = fleetWndProc
        wc.hInstance = GetModuleHandleW(nil)
        // Own background brush: letting the class paint COLOR_BTNFACE
        // flashes light grey behind a dark panel on every resize.
        wc.hbrBackground = CreateSolidBrush(bg)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
        className.withUnsafeBufferPointer { buf in
            wc.lpszClassName = buf.baseAddress
            _ = RegisterClassW(&wc)
        }
        isClassRegistered = true
    }

    // MARK: - window procedure

    private static let fleetWndProc: @convention(c) (HWND?, UINT, WPARAM, LPARAM) -> LRESULT = {
        hwnd, msg, wParam, lParam in
        guard let hwnd else { return DefWindowProcW(hwnd, msg, wParam, lParam) }

        if msg == UINT(WM_NCCREATE) {
            let cs = UnsafePointer<CREATESTRUCTW>(bitPattern: Int(lParam))
            if let ptr = cs?.pointee.lpCreateParams {
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(Int(bitPattern: ptr)))
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        // GetWindowLongPtrW, never a Set/Set dance — that zeroed USERDATA
        // for any message arriving in between and gave the session window
        // a blank first paint (2026-09-04).
        let raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard raw != 0, let ptr = UnsafeMutableRawPointer(bitPattern: Int(raw)) else {
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
        let state = Unmanaged<State>.fromOpaque(ptr).takeUnretainedValue()

        // Int32(bitPattern:), not Int32(_:): Windows sends messages above
        // Int32.max and the checked initializer TRAPS on them ("Not
        // enough bits to represent the passed value", 2026-09-04).
        switch Int32(bitPattern: msg) {
        case WM_CREATE:
            makeFonts(hwnd: hwnd, state: state)
            // The panel drives its OWN refresh rather than depending on
            // the tray's tick: `--panel` runs this window with no tray at
            // all, and it sat on "Reading accounts…" forever because the
            // first read is async and nothing came back to repaint it.
            // Only alive while the window is (killed in WM_DESTROY), and
            // it just re-reads a 30 s cache, so an open panel is cheap and
            // a closed one costs nothing.
            SetTimer(hwnd, refreshTimerId, refreshMilliseconds, nil)
            return 0

        case WM_TIMER:
            // Ask the engine layer to re-shell if ITS cache has expired;
            // it coalesces, so calling every few seconds is free.
            TrayFleet.refresh()
            refresh(hwnd)
            return 0

        case WM_ERASEBKGND:
            // Painted whole in WM_PAINT via a back buffer; erasing here
            // as well is the flicker.
            return 1

        case WM_PAINT:
            paint(hwnd: hwnd, state: state)
            return 0

        case WM_MOUSEMOVE:
            let y = Int32(truncatingIfNeeded: lParam >> 16)
            let row = rowIndex(at: y, hwnd: hwnd, state: state)
            if row != state.hotRow {
                state.hotRow = row
                InvalidateRect(hwnd, nil, false)
                // Ask for WM_MOUSELEAVE so the highlight clears when the
                // pointer exits without crossing a row.
                var track = TRACKMOUSEEVENT()
                track.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
                track.dwFlags = DWORD(TME_LEAVE)
                track.hwndTrack = hwnd
                TrackMouseEvent(&track)
            }
            return 0

        case WM_MOUSELEAVE:
            if state.hotRow != -1 {
                state.hotRow = -1
                InvalidateRect(hwnd, nil, false)
            }
            return 0

        case WM_LBUTTONUP:
            let y = Int32(truncatingIfNeeded: lParam >> 16)
            let index = rowIndex(at: y, hwnd: hwnd, state: state)
            if index >= 0, index < state.panel.rows.count {
                clickRow(state.panel.rows[index], state: state, hwnd: hwnd)
            }
            return 0

        case WM_DPICHANGED:
            // Fonts are sized in device pixels, so a monitor change needs
            // new ones or the panel renders at the old scale.
            makeFonts(hwnd: hwnd, state: state)
            InvalidateRect(hwnd, nil, true)
            return 0

        case WM_CLOSE:
            DestroyWindow(hwnd)
            return 0

        case WM_DESTROY:
            KillTimer(hwnd, refreshTimerId)
            open = nil
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0)
            Unmanaged<State>.fromOpaque(ptr).release()
            return 0

        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam)
        }
    }

    /// Which row a client-area y lands on, or -1.
    private static func rowIndex(at y: Int32, hwnd: HWND, state: State) -> Int {
        let metrics = Metrics(hwnd: hwnd)
        let top = metrics.headerHeight
        guard y >= top else { return -1 }
        let index = Int((y - top) / metrics.rowHeight)
        return index < state.panel.rows.count ? index : -1
    }

    /// Clicking a row switches to that account — the engine decides, we
    /// forward and report (CLAUDE.md: account policy is the engine's).
    private static func clickRow(_ row: FleetLayout.Row, state: State, hwnd: HWND) {
        guard !row.active, !state.switching else { return }
        state.switching = true
        TrayFleet.requestSwitch(to: row.number) { message in
            state.switching = false
            // The reply lands on a worker thread; the tray's own window
            // owns the balloon, and this window just needs repainting.
            TrayFleet.invalidate()
            TrayFleet.refresh(force: true)
            postEngineReport(message)
            if IsWindow(hwnd) { InvalidateRect(hwnd, nil, false) }
        }
    }

    // MARK: - fonts

    private static func makeFonts(hwnd: HWND, state: State) {
        for font in [state.titleFont, state.bodyFont, state.captionFont] {
            if let font { DeleteObject(font) }
        }
        let metrics = Metrics(hwnd: hwnd)
        state.titleFont = font(height: metrics.px(-15), bold: true)
        state.bodyFont = font(height: metrics.px(-13), bold: false)
        state.captionFont = font(height: metrics.px(-11), bold: false)
    }

    private static func font(height: Int32, bold: Bool) -> HFONT? {
        let face = Array("Segoe UI".utf16) + [0]
        return face.withUnsafeBufferPointer { buf in
            CreateFontW(height, 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL,
                        0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH | FF_DONTCARE), buf.baseAddress)
        }
    }

    // MARK: - painting

    private static func paint(hwnd: HWND, state: State) {
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        var client = RECT()
        GetClientRect(hwnd, &client)
        // Double-buffered: drawing rows straight to the window tears
        // visibly on a resize.
        guard let memDC = CreateCompatibleDC(dc),
              let bitmap = CreateCompatibleBitmap(dc, client.right, client.bottom)
        else { return }
        let oldBitmap = SelectObject(memDC, bitmap)
        defer {
            BitBlt(dc, 0, 0, client.right, client.bottom, memDC, 0, 0, DWORD(SRCCOPY))
            SelectObject(memDC, oldBitmap)
            DeleteObject(bitmap)
            DeleteDC(memDC)
        }

        fill(memDC, client, bg)
        SetBkMode(memDC, TRANSPARENT)
        let metrics = Metrics(hwnd: hwnd)

        // Header
        if let font = state.titleFont { SelectObject(memDC, font) }
        draw(memDC, "Infinitus", x: metrics.pad, y: metrics.px(7), color: text)

        if let empty = state.panel.empty {
            if let font = state.bodyFont { SelectObject(memDC, font) }
            drawWrapped(memDC, empty,
                        RECT(left: metrics.pad, top: metrics.headerHeight,
                             right: client.right - metrics.pad,
                             bottom: client.bottom - metrics.footerHeight),
                        color: dim)
        } else {
            for (index, row) in state.panel.rows.enumerated() {
                let top = metrics.headerHeight + Int32(index) * metrics.rowHeight
                paintRow(memDC, row, index: index, top: top, width: client.right,
                         metrics: metrics, state: state)
            }
        }

        // Footer
        if let font = state.captionFont { SelectObject(memDC, font) }
        draw(memDC, state.panel.footer, x: metrics.pad,
             y: client.bottom - metrics.footerHeight + metrics.px(6), color: faint)
        let hint = state.panel.rows.count > 1 ? "click an account to switch" : ""
        if !hint.isEmpty {
            let size = textExtent(memDC, hint)
            draw(memDC, hint, x: client.right - metrics.pad - size.cx,
                 y: client.bottom - metrics.footerHeight + metrics.px(6), color: faint)
        }
    }

    private static func paintRow(_ dc: HDC, _ row: FleetLayout.Row, index: Int,
                                 top: Int32, width: Int32, metrics: Metrics, state: State) {
        let rect = RECT(left: metrics.pad / 2, top: top,
                        right: width - metrics.pad / 2, bottom: top + metrics.rowHeight - 2)
        // Active reads as selected (the screenshot's blue band); hover is
        // a lighter plate so a click target is obvious.
        if row.active {
            fill(dc, rect, activeBg)
        } else if index == state.hotRow {
            fill(dc, rect, rowBg)
        }

        var x = metrics.pad
        let baseline = top + metrics.px(7)

        if let font = state.captionFont { SelectObject(dc, font) }
        draw(dc, "\(row.number)", x: x, y: baseline + metrics.px(2),
             color: row.active ? text : faint)
        x += metrics.numberWidth

        if let font = state.bodyFont { SelectObject(dc, font) }
        // Truncate rather than overflow into the gauges.
        let name = row.disabled ? "\(row.name) (held)" : row.name
        drawClipped(dc, name, x: x, y: baseline, maxWidth: metrics.nameWidth - metrics.px(6),
                    color: row.dead ? dim : text)

        if let note = row.deadNote {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, note, x: x, y: baseline + metrics.px(17),
                        maxWidth: metrics.nameWidth - metrics.px(6), color: dangerColor)
        } else if !row.active {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, row.email, x: x, y: baseline + metrics.px(17),
                        maxWidth: metrics.nameWidth - metrics.px(6), color: faint)
        }
        x += metrics.nameWidth

        for gauge in row.gauges {
            paintGauge(dc, gauge, x: x, top: baseline, metrics: metrics, state: state)
            x += metrics.barWidth + metrics.gaugeGap + metrics.px(52)
        }
    }

    /// Label, percentage, bar, reset caption — the Mac's `windowCell`
    /// laid out by hand.
    private static func paintGauge(_ dc: HDC, _ gauge: FleetLayout.Gauge,
                                   x: Int32, top: Int32, metrics: Metrics, state: State) {
        let tint = color(for: gauge)
        if let font = state.captionFont { SelectObject(dc, font) }
        draw(dc, gauge.label, x: x, y: top + metrics.px(2), color: tint)
        // Measure the label instead of assuming a fixed cell: "5h" and
        // "7d" fit anything, but a model name ("Fable") ran straight into
        // its own percentage (seen 2026-09-04). Clamped so one very long
        // name can't shove the number out of the row.
        let labelWidth = min(metrics.px(56),
                             textExtent(dc, gauge.label).cx + metrics.px(5))

        if let font = state.bodyFont { SelectObject(dc, font) }
        let percent = "\(Int(gauge.usedPct.rounded()))%"
        draw(dc, percent, x: x + labelWidth, y: top,
             color: gauge.spent ? dangerColor : text)

        // The bar sits under the numbers, full width of the cell.
        let barTop = top + metrics.px(20)
        let barRect = RECT(left: x, top: barTop,
                           right: x + metrics.barWidth, bottom: barTop + metrics.barHeight)
        fill(dc, barRect, track)

        // Fill is REMAINING, not used — HP semantics, so a fresh account
        // shows a full bar (GaugeMath.remaining).
        let filled = Int32((Double(metrics.barWidth) * gauge.remaining / 100).rounded())
        if filled > 0 {
            fill(dc, RECT(left: x, top: barTop, right: x + filled,
                          bottom: barTop + metrics.barHeight), tint)
        }

        // Pace, shown statically: a tick where the burn SHOULD be, warm
        // when usage is ahead of the clock, cool when it is behind. The
        // Mac animates this; a repaint timer here would break CLAUDE.md's
        // idle-CPU rule, so the information is kept and the motion isn't.
        if gauge.burnHeat > 0 || gauge.chill > 0 {
            let ahead = gauge.burnHeat > 0
            let markColor = ahead ? warmTint : coolTint
            let intensity = ahead ? gauge.burnHeat : gauge.chill
            let markWidth = max(metrics.px(2), Int32((Double(metrics.px(10)) * intensity).rounded()))
            let markLeft = min(x + metrics.barWidth - markWidth, x + filled)
            fill(dc, RECT(left: max(x, markLeft), top: barTop - metrics.px(1),
                          right: max(x, markLeft) + markWidth,
                          bottom: barTop + metrics.barHeight + metrics.px(1)), markColor)
        }

        if let reset = gauge.reset {
            if let font = state.captionFont { SelectObject(dc, font) }
            drawClipped(dc, reset, x: x, y: barTop + metrics.barHeight + metrics.px(3),
                        maxWidth: metrics.barWidth + metrics.px(46), color: faint)
        }
    }

    // MARK: - GDI helpers

    private static func fill(_ dc: HDC, _ rect: RECT, _ color: COLORREF) {
        guard let brush = CreateSolidBrush(color) else { return }
        var r = rect
        FillRect(dc, &r, brush)
        DeleteObject(brush)
    }

    private static func draw(_ dc: HDC, _ text: String, x: Int32, y: Int32, color: COLORREF) {
        SetTextColor(dc, color)
        let wide = Array(text.utf16)
        var rect = RECT(left: x, top: y, right: x + 4000, bottom: y + 200)
        wide.withUnsafeBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, Int32(buf.count), &rect,
                          UINT(DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX))
        }
    }

    /// Single line, ellipsised at `maxWidth` — a long alias must not run
    /// under the gauges.
    private static func drawClipped(_ dc: HDC, _ text: String, x: Int32, y: Int32,
                                    maxWidth: Int32, color: COLORREF) {
        SetTextColor(dc, color)
        var wide = Array(text.utf16) + [0]
        var rect = RECT(left: x, top: y, right: x + maxWidth, bottom: y + 200)
        wide.withUnsafeMutableBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, -1, &rect,
                          UINT(DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS))
        }
    }

    private static func drawWrapped(_ dc: HDC, _ text: String, _ rect: RECT, color: COLORREF) {
        SetTextColor(dc, color)
        var wide = Array(text.utf16) + [0]
        var r = rect
        wide.withUnsafeMutableBufferPointer { buf in
            _ = DrawTextW(dc, buf.baseAddress, -1, &r,
                          UINT(DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX))
        }
    }

    private static func textExtent(_ dc: HDC, _ text: String) -> SIZE {
        var size = SIZE()
        let wide = Array(text.utf16)
        wide.withUnsafeBufferPointer { buf in
            GetTextExtentPoint32W(dc, buf.baseAddress, Int32(buf.count), &size)
        }
        return size
    }
}
