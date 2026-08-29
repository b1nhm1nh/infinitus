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
@MainActor
final class StatusItemHolder: ObservableObject {
    let controller: StatusItemController
    init(model: AppModel, usage: UsageModel) {
        controller = StatusItemController(model: model, usage: usage)
        model.showPinned = { [weak controller] in controller?.showPinnedWindow() }
    }
}

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var pinned: NSWindow?
    private let model: AppModel
    private let usage: UsageModel
    private var sink: AnyCancellable?

    init(model: AppModel, usage: UsageModel) {
        self.model = model
        self.usage = usage
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []                       // not user-removable
        item.button?.title = model.title
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        popover.behavior = .transient            // click-outside closes, like MenuBarExtra
        popover.contentViewController = NSHostingController(
            rootView: MenuContent(model: model, usage: usage))

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
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// The "sticky" surface: same content in a real window that stays put.
    func showPinnedWindow() {
        if pinned == nil {
            let host = NSHostingController(rootView: MenuContent(model: model, usage: usage))
            let w = NSWindow(contentViewController: host)
            w.title = "CswapBar"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 480))
            pinned = w
        }
        NSApp.activate(ignoringOtherApps: true)
        pinned?.makeKeyAndOrderFront(nil)
    }
}
