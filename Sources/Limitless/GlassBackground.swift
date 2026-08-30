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

/// Side-effect view: fades the popover frame's own material so our glass
/// layer supplies the look. Draws nothing itself.
///
/// macOS 26 frame anatomy (probed 2026-08-30): NSPopoverFrame is itself
/// an NSVisualEffectView hosting a private NSGlassView, whose OWN
/// _NSCoreHostingView sibling of ContentHolderView paints the heavy
/// popover material — our content hangs inside ContentHolderView, so
/// fading that hosting view fades only the frame's paint. Probe-verified:
/// backdrop text reads through crisply, rounded border survives.
private final class FrameRetunerView: NSView {
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let w = window else { return }
        applyToFrame()
        // The frame reacts to key transitions (the base effect view
        // follows window activity, the private glass repaints), so the
        // retune must chase every transition, not run once (user
        // 2026-08-30: "out of focus needs to look the same too").
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            tokens.append(nc.addObserver(forName: name, object: w,
                                         queue: .main) { [weak self] _ in
                self?.applyToFrame()
            })
        }
        // App-level deactivation also drops the window's active
        // appearance without a resign-key on this window.
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil,
                                         queue: .main) { [weak self] _ in
                self?.applyToFrame()
            })
        }
    }

    /// The genuine glass render is keyed off the window's private
    /// "active appearance" — without this, an unfocused window swaps
    /// glass for a flat frosted fallback and the transparency dial
    /// becomes plain opacity (user 2026-08-30: "doesn't look like glass
    /// transparency but just opacity"). Probe-verified: forcing it back
    /// on restores real backdrop blur while unfocused. Guarded so a
    /// future macOS that drops the selector just degrades to frosted.
    private func forceActiveAppearance() {
        guard let w = window, !w.isKeyWindow else { return }
        let sel = NSSelectorFromString("_setHasActiveAppearance:")
        guard w.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: w), sel)
        else { return }
        typealias SetBool = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: SetBool.self)(w, sel, true)
    }

    /// Frame paint alpha ceiling; the per-focus strength dial scales it.
    var paintAlpha: CGFloat = 0.2 {
        didSet { if paintAlpha != oldValue { applyToFrame() } }
    }

    private func applyToFrame() {
        forceActiveAppearance()
        // Once more after AppKit's own key-state handling settles — the
        // notification order between our observer and the appearance
        // drop is not guaranteed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.forceActiveAppearance()
        }
        guard let frameView = window?.contentView?.superview else { return }
        // NSPopoverFrame itself is an effect view following window
        // activity — inactive it swaps to a grayer, more solid material.
        if let base = frameView as? NSVisualEffectView {
            base.state = .active
        }
        retune(frameView)
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    private func retune(_ frame: NSView) {
        for sub in frame.subviews {
            if String(describing: type(of: sub)) == "NSGlassView" {
                for inner in sub.subviews
                where String(describing: type(of: inner)).contains("HostingView") {
                    inner.alphaValue = paintAlpha
                }
            }
            // Pre-26 frames kept their material in effect-view subviews.
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
    var paintAlpha: CGFloat

    func makeNSView(context: Context) -> FrameRetunerView {
        let view = FrameRetunerView()
        view.paintAlpha = paintAlpha
        return view
    }
    func updateNSView(_ view: FrameRetunerView, context: Context) {
        view.paintAlpha = paintAlpha
    }
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
        // The user tunes chrome strength separately per focus state —
        // the unfocused glass renders as a milkier frosted fallback, so
        // one dial can't serve both (2026-08-30: "I'll tune it").
        let strength = isKey ? model.glassFocused : model.glassUnfocused
        ZStack {
            FrameRetuner(paintAlpha: 0.2 * strength)
            if #available(macOS 26.0, *) {
                GlassEffectLayer().opacity(strength)
            } else {
                GlassBackground().opacity(strength)
            }
            let theme = model.rowTheme
            if !theme.plain, !theme.flashColor.isEmpty {
                let tint = ThemeColor.resolve(theme.flashColor)
                LinearGradient(
                    colors: [tint.opacity(0.16 * strength),
                             tint.opacity(0.04 * strength)],
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

/// AppKit Liquid Glass (macOS 26): the genuine article, live in every
/// focus state. In a popover window the stock view subdues itself when
/// the window resigns key (milkier, less backdrop); the subclass pins
/// the private _subduedState at 0 on every key transition so focused
/// and unfocused read identically (user 2026-08-30).
@available(macOS 26.0, *)
private final class SteadyGlassView: NSGlassEffectView {
    // A view attached to a never-key window is born subdued; the
    // neutered key handler only stops later transitions.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setValue(0, forKey: "_subduedState")
    }

    static let neuter: Void = {
        let sel = NSSelectorFromString("_windowChangedKeyState")
        let imp = imp_implementationWithBlock({ (v: NSView) in
            v.setValue(0, forKey: "_subduedState")
        } as @convention(block) (NSView) -> Void)
        class_addMethod(SteadyGlassView.self, sel, imp, "v@:")
    }()
}

@available(macOS 26.0, *)
private struct GlassEffectLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        _ = SteadyGlassView.neuter
        let view = SteadyGlassView()
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
