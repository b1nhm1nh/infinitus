import AppKit
import SwiftUI
import Combine
import CswapCore

/// The menu bar presence, owned directly as an NSStatusItem instead of a
/// SwiftUI MenuBarExtra scene. Two hard-won reasons (2026-08-29, macOS 26,
/// menu bar completely full):
///   1. A removal-allowed item that stops fitting is EVICTED and persisted
///      as user-removed; `behavior = []` makes the item non-removable, so
///      the bar squeezes it (Clock-style) instead of erasing it.
///   2. MenuBarExtra kept SwiftUI's attribute graph in a 100%-CPU
///      insert/evict retry war whenever the app was alive while the bar
///      refused its item — starving the main actor so completely that no
///      snapshot ever completed. A raw NSStatusItem doesn't fight.
/// StateObject-compatible owner so the App struct (a value type that gets
/// recreated) keeps exactly one controller alive.
/// One settings pane: toolbar label + SF Symbol + content.
struct SettingsTab {
    let title: String
    let symbol: String
    /// Sidebar icon tile color (CodexBar-style settings list).
    var tint: Color = .accentColor
    /// Extra search terms beyond the title.
    var keywords: [String] = []
    let view: AnyView
}

@MainActor
final class StatusItemHolder: ObservableObject {
    let controller: StatusItemController
    init(model: AppModel, usage: UsageModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        controller = StatusItemController(model: model, usage: usage,
                                          settingsTabs: settingsTabs)
        model.showSettings = { [weak controller] in controller?.showSettingsWindow() }
        model.reopenPopover = { [weak controller] in controller?.reopenPopover() }
        model.popOut = { [weak controller] in controller?.popOut() }
    }
}

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var pinned: NSWindow?
    /// Last content size PinnedRoot reported — it fires during
    /// NSWindow(contentViewController:) itself, before `pinned` is set.
    private var pinnedIdeal: CGSize = .zero
    private var settings: NSWindow?
    private let model: AppModel
    private let usage: UsageModel
    private let settingsTabs: () -> [SettingsTab]
    private var sink: AnyCancellable?

    init(model: AppModel, usage: UsageModel,
         settingsTabs: @escaping () -> [SettingsTab]) {
        self.model = model
        self.usage = usage
        self.settingsTabs = settingsTabs
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []                       // not user-removable
        item.button?.title = model.title
        // The Limitless glyph rides as a template image so the bar can
        // tint it; the title is text-only percentages now (MenuBarGlyph
        // replaced the "⇄" text prefix, user request 2026-08-30).
        item.button?.image = MenuBarGlyph.image
        item.button?.imagePosition = model.title.isEmpty ? .imageOnly : .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient            // click-outside closes, like MenuBarExtra
        let host = NSHostingController(
            rootView: MenuContent(model: model, usage: usage)
                .glassChrome())
        // NSPopover observes its content controller's preferredContentSize;
        // without this the popover keeps the width of the FIRST layout (no
        // reset times yet) and clips both edges once the grid grows.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // The title and visibility follow the model; receive AFTER the
        // change lands (objectWillChange fires before mutation).
        sink = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.apply() }
            }
    }

    private func apply() {
        item.button?.title = model.title
        item.button?.imagePosition = model.title.isEmpty ? .imageOnly : .imageLeading
        if item.isVisible != model.menuBarIconShown {
            item.isVisible = model.menuBarIconShown
        }
        // Pinned = survives click-outside; the status item still toggles
        // it closed, so a pinned popover can never strand.
        popover.behavior = model.popoverPinned ? .applicationDefined : .transient
    }

    /// The pop-out action: close the popover, open the floating window.
    /// Toggles — with the traffic lights hidden, the same button is how
    /// the window goes away again (Cmd+W works too).
    func popOut() {
        if let pinned, pinned.isVisible {
            pinned.orderOut(nil)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        showPinnedWindow()
    }

    /// Bounce an open popover so it re-measures a wholesale content-shape
    /// change (layout toggle). No-op when closed.
    func reopenPopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let button = self.item.button else { return }
            self.popover.behavior = self.model.popoverPinned ? .applicationDefined : .transient
            NSApp.activate(ignoringOtherApps: true)
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func togglePopover() {
        // A visible pop-out owns the content: the menu bar item focuses it
        // instead of opening a second copy as a popover (user request).
        if let pinned, pinned.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            pinned.makeKeyAndOrderFront(nil)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.behavior = model.popoverPinned ? .applicationDefined : .transient
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Same content in a real window. No popup button opens this any more
    /// (Pin now holds the popover itself); it remains the guaranteed way in
    /// via `open Limitless.app` -> applicationShouldHandleReopen when the
    /// status item is hidden or the bar refuses it.
    func showPinnedWindow() {
        if pinned == nil {
            let host = NSHostingController(rootView: PinnedRoot(
                model: model, usage: usage,
                onSize: { [weak self] size in self?.fitPinned(to: size) })
                .glassChrome())
            // NO hosting-driven window sizing: with .standardBounds or
            // .preferredContentSize, NSHostingView.updateAnimatedWindowSize
            // pushed the content's unbounded ideal width (2.4e196) into
            // setFrame and AppKit threw NSInternalInconsistencyException —
            // the app died on every pop-out (crash reports 22:33–23:08).
            // PinnedRoot measures its own fixedSize() geometry and reports
            // it through onSize; that number is the popover's exact width.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Limitless"
            // Full-size content + hidden system title: the centered
            // "Limitless" header is drawn by PinnedRoot instead (the
            // system title sits leading-aligned next to where the traffic
            // lights were; user wants it centered).
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // No traffic lights at all (user request): the pop-out button
            // toggles the window away, and Cmd+W still closes (.closable
            // stays in the mask for exactly that).
            for button in [NSWindow.ButtonType.closeButton,
                           .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(button)?.isHidden = true
            }
            // The whole point of popping out is staying visible while you
            // work elsewhere — float above normal windows like the pinned
            // popover does.
            w.level = .floating
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // Let the GlassBackground's behind-window material actually
            // see behind the window.
            w.isOpaque = false
            w.backgroundColor = .clear
            pinned = w
            fitPinned(to: pinnedIdeal)
        }
        NSApp.activate(ignoringOtherApps: true)
        pinned?.makeKeyAndOrderFront(nil)
    }

    /// Track the content's measured ideal size (layout, theme, compact,
    /// popup-size changes) — the popover's re-measure, done by hand.
    private func fitPinned(to size: CGSize) {
        pinnedIdeal = size
        guard let pinned, size.width > 1, size.height > 1,
              size.width < 20_000, size.height < 20_000 else { return }
        let current = pinned.contentRect(forFrameRect: pinned.frame).size
        if abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 {
            pinned.setContentSize(NSSize(width: size.width, height: size.height))
        }
    }

    /// Controller-owned Settings window. NOT the SwiftUI Settings scene:
    /// `NSApp.sendAction(showSettingsWindow:)` does nothing on macOS 26
    /// (verified live — synthetic click on the button, no window), and the
    /// openSettings environment action doesn't exist outside the scene
    /// graph. Owning the window outright works from any host.
    /// CodexBar-style chrome: searchable icon sidebar + detail pane
    /// (SettingsRoot), replacing the old toolbar-tab NSTabViewController.
    func showSettingsWindow() {
        if settings == nil {
            let host = NSHostingController(rootView: SettingsRoot(tabs: settingsTabs()))
            // No sizing input from the content: .standardBounds constraints
            // pin the window to SwiftUI's ideal size and beat the
            // .resizable style bit. Sized once, below; the user owns it
            // from there.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Limitless"
            w.styleMask = [.titled, .closable, .resizable]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            // Float only while KEY: opened from the floating pop-out it
            // must land in front of it, but a backgrounded Settings window
            // has no business sitting over other apps (the "always on
            // top" bug, 2026-08-30). The level follows key status.
            w.level = .floating
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsKeyChanged),
                name: NSWindow.didBecomeKeyNotification, object: w)
            NotificationCenter.default.addObserver(
                self, selector: #selector(settingsKeyChanged),
                name: NSWindow.didResignKeyNotification, object: w)
            w.setContentSize(NSSize(width: 780, height: 540))
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsKeyChanged() {
        guard let w = settings else { return }
        w.level = w.isKeyWindow ? .floating : .normal
    }
}

/// The pop-out window's content: the shared popup body under a centered
/// title header (which doubles as the drag strip where the titlebar was).
private struct PinnedRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LimitlessHeader(model: model)
                .frame(height: 30)
            MenuContent(model: model, usage: usage, showHeader: false)
        }
        // fixedSize = the content's ideal, independent of the window; the
        // window then follows THAT (fitPinned) instead of the other way
        // round, so wide rows never compress into wrapped lines.
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // fullSizeContentView hands the hosting view a titlebar-high top
        // safe-area inset, which rendered as a dead strip above the header
        // (user screenshot 2026-08-30); the header IS the titlebar here.
        .ignoresSafeArea(.container, edges: .top)
    }
}
