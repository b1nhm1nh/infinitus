import SwiftUI
import AppKit

/// macOS glass for the popover and the pop-out window (user request
/// 2026-08-30): a behind-window vibrancy material, so the desktop shows
/// through the chrome. `.hudWindow` after the first pass with `.menu`
/// read as near-solid in dark mode ("looks nothing glassy to me") —
/// hud is the most translucent standard material.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PopoverGlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The reason the popup "still doesn't look glassy" (user, 2026-08-30,
/// third report): inside an NSPopover our effect view sits ON TOP of the
/// popover's own frame, which draws the near-opaque system `.popover`
/// material underneath — whatever we stack above it, the backdrop stays
/// solid. The fix is to retarget that frame's OWN effect view to the
/// translucent hud material when we land in the popover window.
private final class PopoverGlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let frameView = window?.contentView?.superview else { return }
        retune(frameView)
    }

    private func retune(_ view: NSView) {
        for sub in view.subviews {
            if let effect = sub as? NSVisualEffectView, effect !== self {
                effect.material = .hudWindow
                effect.state = .active
            }
            retune(sub)
        }
    }
}

/// The popup container's full chrome: behind-window blur, a theme-tinted
/// wash riding on it (container themification, user request 2026-08-30),
/// and on macOS 26 the Liquid Glass material on top. Observes the model
/// so a theme change re-tints the live popup.
struct ThemedGlassChrome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            // Round 6 (2026-08-30): the hud material ALONE. Six states
            // later, the ledger reads:
            //  - hud + frame retune  -> glass on anchored popup AND the
            //    pop-out, focused or not (screenshot-verified).
            //  - NSGlassEffectView alone -> stunning focused pop-out,
            //    NO glass anchored (popover frame stays opaque), NO
            //    glass unfocused (the view deactivates with the window).
            //  - any STACK of the two -> the glass view re-opacifies the
            //    composite: "glass is nowhere to be seen".
            // So: no NSGlassEffectView. The hud layer does everything.
            GlassBackground()
            let theme = model.rowTheme
            if !theme.plain, !theme.flashColor.isEmpty {
                // Container themification: a visible top-down wash plus a
                // tinted edge glow ("not seeing as too themified", user
                // 2026-08-30 — 0.16 read as nothing over the blur).
                let tint = ThemeColor.resolve(theme.flashColor)
                LinearGradient(
                    colors: [tint.opacity(0.30), tint.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    .padding(1)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Glass + themed tint behind the popover / pop-out content.
    /// Compiled against the 26 SDK; guarded for the 14 deployment target.
    func glassChrome(model: AppModel) -> some View {
        background { ThemedGlassChrome(model: model) }
    }
}
