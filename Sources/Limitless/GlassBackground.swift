import SwiftUI
import AppKit

/// macOS glass for the popover and the pop-out window. Two materials,
/// swapped by window focus (round 7, 2026-08-30 — user: "why can't you
/// just build premium glass for every state?"):
///  - KEY window  -> NSGlassEffectView, the real macOS 26 Liquid Glass.
///  - not key     -> NSVisualEffectView hud, state .active — the glass
///    view deactivates with the window (verified: unfocused pop-out went
///    solid), the hud material does not.
/// In BOTH cases FrameRetuner rewrites the NSPopover frame's own
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

/// Reports whether the hosting window is key, live.
private final class KeyWatchView: NSView {
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let w = window else { return }
        onChange?(w.isKeyWindow)
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: w,
            queue: .main) { [weak self] _ in self?.onChange?(true) })
        tokens.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification, object: w,
            queue: .main) { [weak self] _ in self?.onChange?(false) })
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

private struct WindowKeyState: NSViewRepresentable {
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> KeyWatchView {
        let view = KeyWatchView()
        view.onChange = { key in
            DispatchQueue.main.async { isKey = key }
        }
        return view
    }
    func updateNSView(_ view: KeyWatchView, context: Context) {}
}

/// The popup container's full chrome: focus-swapped glass, a theme-tinted
/// wash, and a themed border glow. Observes the model so a theme change
/// re-tints the live popup.
struct ThemedGlassChrome: View {
    @ObservedObject var model: AppModel
    @State private var isKey = false

    var body: some View {
        ZStack {
            FrameRetuner()
            if #available(macOS 26.0, *), isKey {
                GlassEffectLayer()
            } else {
                GlassBackground()
            }
            let theme = model.rowTheme
            if !theme.plain, !theme.flashColor.isEmpty {
                let tint = ThemeColor.resolve(theme.flashColor)
                LinearGradient(
                    colors: [tint.opacity(0.30), tint.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    .padding(1)
            }
        }
        .background(WindowKeyState(isKey: $isKey))
        .ignoresSafeArea()
    }
}

/// AppKit Liquid Glass (macOS 26): the genuine article. Only shown while
/// the window is key — it deactivates (goes solid) otherwise.
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
