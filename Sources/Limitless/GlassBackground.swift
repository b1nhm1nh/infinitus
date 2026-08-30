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
            GlassBackground()
            let theme = model.rowTheme
            if !theme.plain, !theme.flashColor.isEmpty {
                LinearGradient(
                    colors: [ThemeColor.resolve(theme.flashColor).opacity(0.16),
                             ThemeColor.resolve(theme.flashColor).opacity(0.03)],
                    startPoint: .top, endPoint: .bottom)
            }
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: .rect)
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
