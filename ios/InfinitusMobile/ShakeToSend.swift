import SwiftUI
import UIKit
import InfinitusCore

/// Shake the phone on any screen: the app captures what's showing and
/// asks which session to send it to (user 2026-09-04: "the capture
/// button now actually only works in sessions, what if I want to
/// capture other screens?"). A chat's own camera button stays the
/// one-tap path when the target is obvious.
struct ShakeToSend: View {
    @ObservedObject var model: MirrorModel
    @State private var capture: UIImage?
    @State private var asking = false
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        ShakeDetector {
            guard !asking, !sending, let image = ScreenshotWatch.captureApp() else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            capture = image
            asking = true
        }
        .confirmationDialog("Send this screen to…", isPresented: $asking, titleVisibility: .visible) {
            ForEach(sessions, id: \.pid) { session in
                Button(title(session)) { send(to: session) }
            }
            Button("Cancel", role: .cancel) { capture = nil }
        }
        .alert("Couldn't send the screenshot", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var sessions: [SessionDetail] {
        (model.liveSessions?.sessions ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    private func title(_ session: SessionDetail) -> String {
        let name = model.sessionProgress.byPid[session.pid]?.name
            ?? URL(fileURLWithPath: session.cwd).lastPathComponent
        return "\(name) · \(SessionWords.status(session.status, theme: model.rowTheme))"
    }

    private func send(to session: SessionDetail) {
        guard let image = capture, let jpeg = ScreenshotWatch.jpeg(image) else {
            failure = "couldn't read the capture"
            return
        }
        sending = true
        capture = nil
        Task {
            defer { sending = false }
            do {
                let reply = try await NetworkFleetMirror.shared.sessionInput(
                    pid: Int32(session.pid),
                    request: .init(kind: .message,
                                   text: "Screenshot of the Infinitus app, taken on the phone just now.",
                                   attachments: [.init(name: "app-screenshot.jpg", mime: "image/jpeg", data: jpeg)]))
                if reply.outcome == "delivered" {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    failure = reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome
                }
            } catch {
                failure = "couldn't reach the Mac"
            }
        }
    }
}

/// A shake, as UIKit reports it: a responder that asks to be first when
/// it appears. A focused text field keeps first responder and its own
/// shake (undo) — the composer is not where this is for.
private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller()
        c.onShake = onShake
        return c
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onShake = onShake
    }

    final class Controller: UIViewController {
        var onShake: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake?() }
            super.motionEnded(motion, with: event)
        }
    }
}
