import SwiftUI
import WebKit
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
    private var master: FileHandle?
    private var buffer = ""
    private var token: String?
    private var shimDir: URL?
    private var authWindow: NSWindow?

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
            phase = .failed(tail.isEmpty
                            ? "setup-token exited \(status) without a token"
                            : String(tail))
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

    // MARK: ephemeral login window

    private func openAuthWindow(_ url: URL) {
        let cfg = WKWebViewConfiguration()
        // A private per-flow store, isolated from the user's browser.
        // Persistent under the account's own identifier so a RELOGIN
        // opens already signed in; a fresh identifier for adds.
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude login (private)"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        authWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    }
}

struct AccountsPane: View {
    @ObservedObject var model: AppModel
    @StateObject private var flow = TokenFlow()
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
