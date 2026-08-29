import SwiftUI
import AppKit

/// macOS glass for the popover and the pop-out window (user request
/// 2026-08-30): a behind-window vibrancy material, so the desktop shows
/// through the chrome. `.menu` because that's the material a menu-bar
/// dropdown wears — adaptive to light/dark, unlike `.hudWindow`.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
