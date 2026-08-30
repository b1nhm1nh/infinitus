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
            // The hud layer is ALWAYS underneath (2026-08-30, round 5):
            // 1) its PopoverGlassView retunes the popover frame's own
            //    near-opaque material — without it the ANCHORED popup has
            //    no glass at all (only the pop-out window did);
            // 2) NSGlassEffectView goes inactive with the window — the
            //    hud (state .active) keeps the unfocused pop-out glassy.
            GlassBackground()
            if #available(macOS 26.0, *) {
                GlassEffectLayer()
            }
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

/// AppKit Liquid Glass (macOS 26): the genuine article, not the SwiftUI
/// approximation. Clear content view; the glass draws the backdrop.
@available(macOS 26.0, *)
private struct GlassEffectLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .clear
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

extension View {
    /// Glass + themed tint behind the popover / pop-out content.
    /// Compiled against the 26 SDK; guarded for the 14 deployment target.
    func glassChrome(model: AppModel) -> some View {
        background { ThemedGlassChrome(model: model) }
    }
}
