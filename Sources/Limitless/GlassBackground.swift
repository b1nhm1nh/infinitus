import SwiftUI
import AppKit

/// macOS glass for the popover and the pop-out window: NSGlassEffectView
/// in EVERY state. The round-7 focus-swap rested on a false observation —
/// a probe window (2026-08-30) proves plain NSGlassEffectView keeps full
/// glass when the window resigns key; the "went solid" repro was the
/// probe being occluded, and in-app the swap itself was what removed the
/// glass. FrameRetuner still rewrites the NSPopover frame's own
/// near-opaque material — without that the anchored popup never shows
/// any backdrop, whatever we stack inside it.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Side-effect view: retunes every effect view in the popover frame to
/// the translucent hud material. Draws nothing itself.
private final class FrameRetunerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let frameView = window?.contentView?.superview else { return }
        retune(frameView)
    }

    private func retune(_ view: NSView) {
        for sub in view.subviews {
            if let effect = sub as? NSVisualEffectView {
                effect.material = .hudWindow
                effect.state = .active
                // Mostly out of the way: the glass layer supplies the
                // look; full-strength hud on top of it reads milky
                // (user 2026-08-30: "increase the transparency").
                effect.alphaValue = 0.35
            }
            retune(sub)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct FrameRetuner: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameRetunerView { FrameRetunerView() }
    func updateNSView(_ view: FrameRetunerView, context: Context) {}
}

/// The popup container's full chrome: focus-swapped glass, a theme-tinted
/// wash, and a themed border glow. Observes the model so a theme change
/// re-tints the live popup.
struct ThemedGlassChrome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            FrameRetuner()
            if #available(macOS 26.0, *) {
                GlassEffectLayer()
            } else {
                GlassBackground()
            }
            let theme = model.rowTheme
            if !theme.plain, !theme.flashColor.isEmpty {
                let tint = ThemeColor.resolve(theme.flashColor)
                LinearGradient(
                    colors: [tint.opacity(0.16), tint.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    .padding(1)
            }
        }
        .ignoresSafeArea()
    }
}

/// AppKit Liquid Glass (macOS 26): the genuine article, live in every
/// focus state.
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
