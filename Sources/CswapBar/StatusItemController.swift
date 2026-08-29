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
    }
}

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var pinned: NSWindow?
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
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient            // click-outside closes, like MenuBarExtra
        let host = NSHostingController(
            rootView: MenuContent(model: model, usage: usage))
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
        if item.isVisible != model.menuBarIconShown {
            item.isVisible = model.menuBarIconShown
        }
        // Pinned = survives click-outside; the status item still toggles
        // it closed, so a pinned popover can never strand.
        popover.behavior = model.popoverPinned ? .applicationDefined : .transient
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
    /// via `open CswapBar.app` -> applicationShouldHandleReopen when the
    /// status item is hidden or the bar refuses it.
    func showPinnedWindow() {
        if pinned == nil {
            let host = NSHostingController(rootView: MenuContent(model: model, usage: usage))
            let w = NSWindow(contentViewController: host)
            w.title = "Limitless"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 480))
            pinned = w
        }
        NSApp.activate(ignoringOtherApps: true)
        pinned?.makeKeyAndOrderFront(nil)
    }

    /// Controller-owned Settings window. NOT the SwiftUI Settings scene:
    /// `NSApp.sendAction(showSettingsWindow:)` does nothing on macOS 26
    /// (verified live — synthetic click on the button, no window), and the
    /// openSettings environment action doesn't exist outside the scene
    /// graph. Owning the window outright works from any host.
    func showSettingsWindow() {
        if settings == nil {
            // NSTabViewController(.toolbar) is the REAL Settings chrome —
            // icon tabs in the titlebar. The SwiftUI Settings scene gets it
            // implicitly; no public TabViewStyle reproduces it.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for tab in settingsTabs() {
                let host = NSHostingController(rootView: tab.view)
                // No sizing input from the children AT ALL: .standardBounds
                // constraints pin the window to SwiftUI's ideal size, and a
                // preferredContentSize makes NSTabViewController re-assert
                // that size — either one beats the .resizable style bit.
                // The window is sized once, below, and the user owns it
                // from there.
                host.sizingOptions = []
                // The toolbar tab style propagates the selected child's
                // title into the window title ("Untitled" when unset).
                host.title = tab.title
                let item = NSTabViewItem(viewController: host)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol,
                                     accessibilityDescription: tab.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.title = "Limitless Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 600, height: 520))
            settings = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}
