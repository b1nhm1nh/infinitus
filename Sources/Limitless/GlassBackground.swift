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

extension View {
    /// The popover / pop-out chrome: behind-window blur always (that's
    /// what lets the desktop through), plus the Liquid Glass material on
    /// macOS 26 riding on it for the refractive look ("do all",
    /// 2026-08-30). Compiled against the 26 SDK; guarded for the 14
    /// deployment target.
    @ViewBuilder func glassChrome() -> some View {
        if #available(macOS 26.0, *) {
            background {
                ZStack {
                    GlassBackground()
                    Color.clear.glassEffect(.regular, in: .rect)
                }
                .ignoresSafeArea()
            }
        } else {
            background { GlassBackground().ignoresSafeArea() }
        }
    }
}
