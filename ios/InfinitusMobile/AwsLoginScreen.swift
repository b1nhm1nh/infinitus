import SwiftUI
import WebKit
import SafariServices
import InfinitusCore

/// AWS sign-in from the phone (user 2026-09-03: "sessions often need
/// `aws login` for SSO — let me log in on mobile, the session
/// continues"). The Mac runs the CLI (AwsLoginRunner); this screen
/// drives it over the mirror channel: `POST /aws-login/start` starts
/// the login and, re-posted, reports its state — that is the poll.
///
/// Three flows, chosen Mac-side (`AwsLogin.flow`):
/// - relay: the CLI's own `aws login` with THIS web view as the browser.
///   The IdP finally redirects to `http://127.0.0.1:<port>/oauth/callback`
///   — a URL only the Mac can reach — so the web view cancels that
///   navigation and posts it verbatim; the Mac replays it against the
///   CLI's listener. Nothing to read or type.
/// - deviceCode: `aws sso login --use-device-code`: the page asks for a
///   short code; shown here, sign-in happens in any browser.
/// - remote: `aws login --remote`: the page shows a code after sign-in;
///   pasted back here. The fallback when an IdP refuses the web view.
@MainActor
final class AwsLoginFlow: ObservableObject {
    let item: AwsLogin.Item
    @Published var state: AwsLogin.State?
    @Published var error: String?
    @Published var busy = false
    /// Relay: the callback was posted; the CLI is finishing.
    @Published var relayed = false
    private var poll: Task<Void, Never>?

    init(item: AwsLogin.Item) {
        self.item = item
        self.state = item.state
        if let s = item.state, s.phase != .done, s.phase != .failed { startPolling() }
    }

    deinit { poll?.cancel() }

    var profile: String { item.profile }
    var flow: AwsLogin.Flow { state?.flow ?? item.flow }
    var finished: Bool { state?.phase == .done || state?.phase == .failed }

    func start(remote: Bool = false) {
        busy = true
        error = nil
        relayed = false
        Task {
            await post(AwsLogin.StartRequest(profile: profile, pid: item.pid, remote: remote ? true : nil))
            busy = false
            startPolling()
        }
    }

    /// Relay: the intercepted `127.0.0.1` callback.
    func relay(_ url: URL) {
        relayed = true
        Task { await post(AwsLogin.CallbackRequest(profile: profile, url: url.absoluteString)) }
    }

    func send(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AwsLogin.isValidCode(code) else {
            error = "That doesn't look like an authorization code."
            return
        }
        busy = true
        Task {
            await post(AwsLogin.CodeRequest(profile: profile, code: code))
            busy = false
        }
    }

    private func post(_ request: AwsLogin.StartRequest) async {
        do { apply(try await NetworkFleetMirror.shared.awsLoginStart(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }
    private func post(_ request: AwsLogin.CallbackRequest) async {
        do { apply(try await NetworkFleetMirror.shared.awsLoginCallback(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }
    private func post(_ request: AwsLogin.CodeRequest) async {
        do { apply(try await NetworkFleetMirror.shared.awsLoginCode(request)) }
        catch { self.error = "Mac didn't answer: \(error.localizedDescription)" }
    }

    private func apply(_ reply: AwsLogin.Reply) {
        if let s = reply.state { state = s }
        if !reply.ok { error = reply.error ?? "The Mac refused." }
        if finished { poll?.cancel(); poll = nil }
    }

    /// Every 2 s while a login is in flight: `start` is idempotent per
    /// profile and answers with the current state.
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.finished else { return }
                if let reply = try? await NetworkFleetMirror.shared.awsLoginStart(
                    AwsLogin.StartRequest(profile: self.profile, pid: self.item.pid)) {
                    self.apply(reply)
                }
            }
        }
    }
}

struct AwsLoginScreen: View {
    @StateObject private var flow: AwsLoginFlow
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var showSafari = false

    init(item: AwsLogin.Item) {
        _flow = StateObject(wrappedValue: AwsLoginFlow(item: item))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AWS login · \(flow.profile)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(flow.finished ? "Done" : "Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        let state = flow.state
        if let state, state.phase == .done {
            outcome(icon: "checkmark.circle.fill", tint: .green,
                    title: "Signed in",
                    text: state.message ?? "The session was told to retry and continue.")
        } else if let state, state.phase == .failed {
            outcome(icon: "xmark.octagon.fill", tint: .red,
                    title: "Login failed", text: state.message ?? "The CLI stopped.") {
                Button("Try again") { flow.start() }.buttonStyle(.borderedProminent)
                if flow.flow == .relay {
                    Button("Use the code flow instead") { flow.start(remote: true) }
                }
            }
        } else if state == nil || state?.url == nil {
            // Not started, or the CLI hasn't printed its URL yet.
            VStack(spacing: 16) {
                if let label = flow.item.sessionLabel {
                    Text("Session **\(label)** is stuck on an expired AWS session for profile **\(flow.profile)**.")
                        .multilineTextAlignment(.center)
                } else {
                    Text("Profile **\(flow.profile)** needs a fresh AWS login.")
                }
                if state != nil || flow.busy {
                    ProgressView("Starting `aws login` on the Mac…")
                } else {
                    Button("Sign in from this phone") { flow.start() }
                        .buttonStyle(.borderedProminent)
                    Text(flowBlurb)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                errorLine
            }
            .padding()
        } else if let state, let url = URL(string: state.url ?? "") {
            switch state.flow {
            case .relay, .local:
                relayView(state: state, url: url)
            case .deviceCode:
                deviceCodeView(state: state, url: url)
            case .remote:
                remoteView(state: state, url: url)
            }
        }
    }

    private var flowBlurb: String {
        switch flow.flow {
        case .relay, .local: return "The sign-in page opens right here; nothing to copy."
        case .deviceCode: return "You'll get a short code to enter on the AWS page."
        case .remote: return "After signing in, AWS shows a code to paste back here."
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let error = flow.error {
            Text(error).font(.footnote).foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func outcome(icon: String, tint: Color, title: String, text: String,
                         @ViewBuilder actions: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(tint)
            Text(title).font(.title2.bold())
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
            errorLine
        }
        .padding()
    }

    // MARK: relay — the web view is the browser

    private func relayView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 0) {
            if flow.relayed {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Signing in… the Mac is finishing the login.")
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(.thinMaterial)
            } else {
                HStack(spacing: 8) {
                    Text("Sign in below. The final redirect goes to the Mac automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Trouble? Use a code") { flow.start(remote: true) }
                        .font(.footnote)
                }
                .padding(10)
                .background(.thinMaterial)
            }
            errorLine.padding(.horizontal)
            RelayWebView(url: url, callbackPort: state.callbackPort) { intercepted in
                flow.relay(intercepted)
            }
            .opacity(flow.relayed ? 0.35 : 1)
        }
    }

    // MARK: device code

    private func deviceCodeView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 18) {
            Text("Enter this code on the AWS page:")
            Text(state.userCode ?? "…")
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button {
                    UIPasteboard.general.string = state.userCode
                } label: { Label("Copy code", systemImage: "doc.on.doc") }
                .disabled(state.userCode == nil)
                Button { showSafari = true } label: {
                    Label("Open sign-in page", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
            ProgressView("Waiting for approval…")
                .font(.footnote).foregroundStyle(.secondary)
            errorLine
        }
        .padding()
        .sheet(isPresented: $showSafari) { SafariSheet(url: url) }
    }

    // MARK: remote — paste the code back

    private func remoteView(state: AwsLogin.State, url: URL) -> some View {
        VStack(spacing: 18) {
            Text("Sign in on the AWS page; it ends with an authorization code. Paste it here.")
                .multilineTextAlignment(.center)
            Button { showSafari = true } label: {
                Label("Open sign-in page", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            TextField("Authorization code", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { flow.send(code: code) }
            Button("Send code") { flow.send(code: code) }
                .buttonStyle(.bordered)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || flow.busy)
            if state.phase == .waitingForBrowser {
                ProgressView("Finishing…").font(.footnote)
            }
            errorLine
        }
        .padding()
        .sheet(isPresented: $showSafari) { SafariSheet(url: url) }
    }
}

/// The relay flow's browser. `decidePolicyFor` sees every navigation:
/// the one to `http://127.0.0.1:<callbackPort>/oauth/callback` is
/// cancelled (the phone can't reach it anyway) and handed back; all
/// else loads. A Safari user agent because some IdPs refuse embedded
/// views by their default UA ("disallowed_useragent").
private struct RelayWebView: UIViewRepresentable {
    let url: URL
    let callbackPort: Int?
    let onCallback: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // a fresh jar per login
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RelayWebView
        private var handed = false
        init(_ parent: RelayWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, isCallback(url) {
                decisionHandler(.cancel)
                guard !handed else { return }
                handed = true
                parent.onCallback(url)
                return
            }
            decisionHandler(.allow)
        }

        private func isCallback(_ url: URL) -> Bool {
            guard url.host == "127.0.0.1" || url.host == "localhost" else { return false }
            if let port = parent.callbackPort { return url.port == port }
            return url.path == "/oauth/callback"
        }
    }
}

private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
