import SwiftUI
import WebKit
import AuthenticationServices
import CswapCore

/// Native account management (user 2026-08-31: "add new account,
/// relogin, delete. do not reuse cswap['s login flow]"). Login is
/// Claude's own OAuth — the app hosts `claude setup-token` on a PTY,
/// shows the OAuth URL in a PRIVATE in-app web window (never the
/// default browser: its claude.ai session belongs to ONE account and
/// switching there means logout/login churn — user 2026-08-31), takes
/// the pasted code, and hands the minted token to the engine over
/// stdin (`cswap add-token -`). The token is shown masked only.
/// Each account keeps its own isolated web session, so Relogin opens
/// already signed in as that account.
@MainActor final class TokenFlow: ObservableObject {
    /// One app-wide flow: the popup's "re-login needed" note starts it
    /// directly from the list (user 2026-08-31), the Accounts pane
    /// mirrors whatever is in flight.
    static let shared = TokenFlow()

    enum Phase: Equatable {
        case idle
        case launching
        case awaitingLogin      // URL captured; web window is up
        case waitingForToken    // code submitted; CLI finishing
        case registering        // token captured; cswap add-token runs
        case done(String)       // masked token tail
        case failed(String)
    }
    @Published var phase: Phase = .idle
    @Published var authURL: URL?
    @Published var code = ""
    /// Which account this flow is for (relogin) — display only; cswap
    /// matches the credential identity itself.
    @Published var reloginTarget: String?
    /// Persistent per-account web session (user 2026-08-31: "if
    /// relogin an account can open that browser session of that
    /// account"): each account gets its own WKWebsiteDataStore
    /// identifier, so a relogin window opens already signed in — the
    /// approve click is usually all that's left. Adds start fresh
    /// under a new identifier, bound to the account once it appears.
    private var storeID = UUID()
    private var reloginEmail: String?
    private var preEmails: Set<String> = []
    private static let mapKey = "auth_web_store_map"

    private static func storeMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: mapKey) as? [String: String] ?? [:]
    }
    private static func bind(email: String, id: UUID) {
        var m = storeMap()
        m[email] = id.uuidString
        UserDefaults.standard.set(m, forKey: mapKey)
    }

    private var process: Process?
    private weak var model: AppModel?
    private var master: FileHandle?
    private var buffer = ""
    private var token: String?
    private var shimDir: URL?
    private var authWindow: NSWindow?
    private var webWindow: NSWindow?
    private var webDelegate: AuthWebDelegate?
    private var systemSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthAnchorProvider?

    var running: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    func start(model: AppModel, relogin: Account? = nil) {
        guard !running else { return }
        reloginTarget = relogin.map { ($0.alias?.isEmpty == false ? $0.alias! : $0.email) }
        reloginEmail = relogin?.email
        preEmails = Set(model.accounts.map(\.email))
        if let email = relogin?.email,
           let saved = Self.storeMap()[email], let id = UUID(uuidString: saved) {
            storeID = id            // reopen THIS account's session
        } else {
            storeID = UUID()        // fresh jar for a fresh login
        }
        code = ""
        token = nil
        buffer = ""
        authURL = nil
        phase = .launching
        self.model = model
        do { try launch(model: model) } catch {
            phase = .failed("couldn't start claude setup-token: \(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
        cleanup()
        phase = .idle
    }

    /// Paste-back: the code from the OAuth success page goes to the
    /// CLI's tty (CR = tty newline).
    func submitCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        master?.write(Data((trimmed + "\r").utf8))
        phase = .waitingForToken
        closeAuthWindow()
    }

    // MARK: plumbing

    private static func claudePath() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude",
                "\(home)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func launch(model: AppModel) throws {
        guard let claude = Self.claudePath() else {
            throw CLIError(message: "claude CLI not found")
        }
        // `open` shim first in the child's PATH: setup-token tries to
        // open the OAuth URL in the default browser itself — the shim
        // swallows that (and stashes the URL as a bonus capture path).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-auth-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shim = dir.appendingPathComponent("open")
        try "#!/bin/sh\necho \"$@\" > \"\(dir.path)/url\"\nexit 0\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shim.path)
        shimDir = dir

        var m: Int32 = 0
        var s: Int32 = 0
        // 500 columns: at the default 80 the TUI hard-wraps its output,
        // splitting the OAuth URL and the minted token across lines —
        // regex capture then truncates (probed live 2026-08-31).
        var ws = winsize(ws_row: 40, ws_col: 500, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &ws) == 0 else {
            throw CLIError(message: "openpty failed")
        }
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        let masterFH = FileHandle(fileDescriptor: m, closeOnDealloc: true)
        master = masterFH

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["setup-token"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TERM"] = "xterm-256color"
        p.environment = env
        p.standardInput = slave
        p.standardOutput = slave
        p.standardError = slave
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.finished(status: proc.terminationStatus,
                                                      model: model) }
        }
        try p.run()
        close(s)
        process = p

        masterFH.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        // The model reference rides the termination handler; nothing
        // else to do until output arrives.
    }

    /// Strip ANSI control sequences (setup-token is a TUI).
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{07}]*\u{07}",
            with: "", options: .regularExpression)
    }

    private func consume(_ chunk: String) {
        buffer += Self.plain(chunk)
        if buffer.count > 20_000 { buffer = String(buffer.suffix(10_000)) }
        // OAuth URL: the shim's stash first — it gets the exact argv
        // URL with no tty wrapping risk; stdout regex is the fallback.
        if authURL == nil {
            var found: String?
            if let dir = shimDir,
               let stash = try? String(contentsOf: dir.appendingPathComponent("url"),
                                       encoding: .utf8),
               !stash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found = stash.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if found == nil, let r = buffer.range(
                of: #"https://[A-Za-z0-9./?#=&%_+~:-]+"#,
                options: .regularExpression) {
                found = String(buffer[r])
            }
            if let found, found.contains("oauth") || found.contains("claude.ai")
                || found.contains("anthropic.com"),
               let url = URL(string: found) {
                authURL = url
                phase = .awaitingLogin
                openAuthWindow(url)
            }
        }
        // The minted long-lived token.
        if let r = buffer.range(of: #"sk-ant-[A-Za-z0-9_\-]{24,}"#,
                                options: .regularExpression) {
            token = String(buffer[r])
        }
    }

    private func finished(status: Int32, model: AppModel) {
        master?.readabilityHandler = nil
        guard let token, status == 0 || token.count > 30 else {
            let tail = buffer.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = tail.isEmpty
                ? "setup-token exited \(status) without a token"
                : String(tail)
            phase = .failed(msg)
            model.lastError = "relogin: \(msg.prefix(120))"
            cleanup()
            return
        }
        phase = .registering
        let masked = "…" + token.suffix(6)
        Task {
            do {
                guard let cli = model.cli else {
                    throw CLIError(message: "no engine")
                }
                try await cli.addToken(token)
                await model.refreshSnapshot()
                // Bind the web session to its account for future
                // relogins: the relogin target, or the one new email.
                if let email = self.reloginEmail {
                    Self.bind(email: email, id: self.storeID)
                } else {
                    let new = Set(model.accounts.map(\.email))
                        .subtracting(self.preEmails)
                    if let email = new.first, new.count == 1 {
                        Self.bind(email: email, id: self.storeID)
                    }
                }
                self.phase = .done(masked)
            } catch {
                self.phase = .failed("engine refused the token: \(error)")
            }
            self.cleanup()
        }
    }

    private func cleanup() {
        closeAuthWindow()
        if let dir = shimDir { try? FileManager.default.removeItem(at: dir) }
        shimDir = nil
        process = nil
        master = nil
        token = nil
    }

    // MARK: login windows

    /// Sheet-first (user 2026-08-31 — the footer-link version was
    /// rejected): capturing the OAuth URL immediately opens the SYSTEM
    /// sign-in sheet, where passkeys, Touch ID and Google all just
    /// work, anchored to a compact companion window holding the
    /// paste-code bar. The per-account private WKWebView window stays
    /// available as the opt-in alternative for isolated sessions.
    private func openAuthWindow(_ url: URL) {
        let host = NSHostingController(rootView: AuthWindowRoot(flow: self))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = reloginTarget.map { "Re-login \u{2014} \($0)" }
            ?? "Add Claude account"
        w.contentViewController = host
        w.setContentSize(NSSize(width: 520, height: 190))
        w.isReleasedWhenClosed = false
        w.center()
        authWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Routing: a relogin target with a saved private session skips
        // the sheet — its own window opens already signed in as THAT
        // account. Everyone else gets the ephemeral sheet (fresh
        // sign-in, passkeys work).
        if let email = reloginEmail, Self.storeMap()[email] != nil {
            openPrivateWindow()
        } else {
            startSystemSheet()
        }
    }

    /// The opt-in private window: this account's own isolated session
    /// (signed in already on later re-logins), Safari UA, popup
    /// hosting. No passkeys — WebAuthn is entitlement-locked to real
    /// browsers; password sign-in works.
    func openPrivateWindow() {
        guard let url = authURL else { return }
        if let w = webWindow { w.makeKeyAndOrderFront(nil); return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/26.0 Safari/605.1.15"
        let delegate = AuthWebDelegate()
        webDelegate = delegate
        web.uiDelegate = delegate
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude login (private)"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        webWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Passkey path (user 2026-08-31: "couldn't use passkey"): WebAuthn
    /// is entitlement-locked to real browsers — a WKWebView only gets
    /// the Bluetooth-hybrid fallback, which fails. The system sheet
    /// (Safari's out-of-process service) has full passkey support.
    /// Its cookie store is app-shared, not per-account — Google's own
    /// account chooser covers multi-account there.
    func startSystemSheet() {
        guard let url = authURL else { return }
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: nil) { [weak self] _, _ in
            // No custom-scheme callback exists — the flow ends when the
            // user copies the code and closes the sheet; nothing to do.
            self?.systemSession = nil
        }
        let provider = AuthAnchorProvider(window: authWindow)
        anchorProvider = provider
        session.presentationContextProvider = provider
        // EPHEMERAL, non-negotiably: the shared sheet store carried
        // account 1's claude session into account 2's relogin ("it
        // opens my account1", user screenshot 2026-08-31). Passkeys
        // don't need cookies — they live in the OS keychain — so a
        // fresh session costs one Touch ID tap and bleeds nothing.
        session.prefersEphemeralWebBrowserSession = true
        systemSession = session
        session.start()
    }

    func reopenAuth() {
        if let w = authWindow {
            w.makeKeyAndOrderFront(nil)
        } else if let url = authURL {
            openAuthWindow(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeAuthWindow() {
        authWindow?.orderOut(nil)
        authWindow = nil
        webWindow?.orderOut(nil)
        webWindow = nil
        webDelegate?.closePopups()
        webDelegate = nil
        systemSession?.cancel()
        systemSession = nil
        anchorProvider = nil
    }
}

/// Presentation anchor for the system sign-in sheet.
final class AuthAnchorProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    private weak var window: NSWindow?
    init(window: NSWindow?) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor {
        window ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// OAuth popup host: window.open from the login page (Google's flow)
/// gets a real child window sharing the SAME configuration — required
/// by WebKit, and what keeps the popup inside the private session.
@MainActor final class AuthWebDelegate: NSObject, WKUIDelegate {
    private var popups: [NSWindow] = []

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = webView.customUserAgent
        web.uiDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return web
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let i = popups.firstIndex(where: { $0.contentView === webView }) {
            popups[i].orderOut(nil)
            popups.remove(at: i)
        }
    }

    func closePopups() {
        popups.forEach { $0.orderOut(nil) }
        popups = []
    }
}

private struct AuthWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The companion window: sign-in status + the paste-code bar. The
/// actual signing-in happens in the system sheet (passkeys work
/// there), which this window anchors.
private struct AuthWindowRoot: View {
    @ObservedObject var flow: TokenFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = flow.reloginTarget {
                Text("Re-login for \(target) \u{2014} sign in as that account.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("1. Sign in and approve in the sign-in sheet or window "
                 + "(the sheet is a fresh private session \u{2014} "
                 + "passkeys and Touch ID work; it never remembers "
                 + "another account).\n"
                 + "2. Copy the code it shows and paste it here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Paste the code shown after approval",
                          text: $flow.code)
                    .textFieldStyle(.roundedBorder)
                Button("Submit") { flow.submitCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.code.trimmingCharacters(
                        in: .whitespaces).isEmpty)
                Button("Cancel") { flow.cancel() }
            }
            HStack(spacing: 6) {
                Button("Reopen sign-in sheet") { flow.startSystemSheet() }
                Button("Use private window instead") {
                    flow.openPrivateWindow()
                }
                .help("An isolated per-account browser session \u{2014} "
                      + "remembers this account's login for the next "
                      + "re-login. No passkeys there; password sign-in "
                      + "works.")
            }
        }
        .padding(14)
        .frame(width: 520, alignment: .leading)
    }
}

struct AccountsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var flow = TokenFlow.shared
    @State private var confirmDelete: Account?

    var body: some View {
        Form {
            Section("Accounts") {
                if model.accounts.isEmpty {
                    Text("No accounts yet — add the first one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.accounts, id: \.number) { a in
                    HStack(spacing: 10) {
                        Text("\(a.number)").monospacedDigit()
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.alias?.isEmpty == false ? a.alias! : a.email)
                                .fontWeight(a.active ? .bold : .regular)
                            if a.alias?.isEmpty == false {
                                Text(a.email).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        statusChip(a)
                        Spacer()
                        if a.usageStatus != "ok" || (a.disabled ?? false) == false {
                            Button("Relogin") {
                                flow.start(model: model, relogin: a)
                            }
                            .disabled(flow.running)
                        }
                        Button(role: .destructive) {
                            confirmDelete = a
                        } label: { Image(systemName: "trash") }
                        .disabled(flow.running)
                        .help("Remove this account from the engine")
                    }
                }
            }
            Section("Add account") {
                flowView
            }
        }
        .formStyle(.grouped)
        .alert("Remove \(confirmDelete?.alias ?? confirmDelete?.email ?? "account")?",
               isPresented: Binding(get: { confirmDelete != nil },
                                    set: { if !$0 { confirmDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = confirmDelete { remove(a) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The engine forgets its stored credential. The Claude "
                 + "account itself is untouched — you can add it back "
                 + "any time.")
        }
    }

    @ViewBuilder private func statusChip(_ a: Account) -> some View {
        if a.disabled ?? false {
            Text("disabled").font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.gray.opacity(0.3)))
        } else if a.usageStatus != "ok" {
            Text(a.usageStatus == "relogin_required"
                 ? "re-login needed" : a.usageStatus)
                .font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.orange.opacity(0.18)))
        } else if a.active {
            Text("active").font(.caption2).foregroundStyle(.green)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.green.opacity(0.18)))
        }
    }

    @ViewBuilder private var flowView: some View {
        switch flow.phase {
        case .idle:
            HStack {
                Button("Add account…") { flow.start(model: model) }
                Text("Opens Claude's login in a private in-app window — "
                     + "your browser session is never touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .launching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting claude setup-token…")
                Button("Cancel") { flow.cancel() }
            }
        case .awaitingLogin:
            VStack(alignment: .leading, spacing: 8) {
                if let target = flow.reloginTarget {
                    Text("Re-login for \(target): sign in as that account.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("1. Sign in and approve in the login window "
                     + "(reopen: button below).\n2. Copy the code it "
                     + "shows, paste it here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Reopen login window") { flow.reopenAuth() }
                    TextField("Paste code", text: $flow.code)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Button("Submit") { flow.submitCode() }
                        .disabled(flow.code.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                    Button("Cancel") { flow.cancel() }
                }
            }
        case .waitingForToken, .registering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.phase == .registering
                     ? "Handing the token to the engine…"
                     : "Waiting for the token…")
                Button("Cancel") { flow.cancel() }
            }
        case .done(let masked):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Token \(masked) registered — account list refreshed.")
                Button("Add another") { flow.start(model: model) }
                Button("Done") { flow.phase = .idle }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                HStack {
                    Button("Try again") { flow.start(model: model) }
                    Button("Dismiss") { flow.phase = .idle }
                }
            }
        }
    }

    private func remove(_ a: Account) {
        Task {
            guard let cli = model.cli else { return }
            do {
                try await cli.removeAccount(a.number)
                await model.refreshSnapshot()
            } catch {
                model.lastError = "\(error)"
            }
        }
    }
}
