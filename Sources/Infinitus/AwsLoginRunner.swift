import Foundation
import InfinitusCore

/// Runs the AWS CLI sign-in for a profile and reports its prompts
/// (AwsLogin.swift). One process per profile at a time; the CLI runs
/// under `script` so its prompts behave as on a terminal, with the code
/// written to its stdin and nothing else. Output is parsed for the URL /
/// code / success line only — never logged whole.
actor AwsLoginRunner {
    private struct Run {
        let process: Process
        let stdin: Pipe
        var output = ""
        var state: AwsLogin.State
    }

    private var runs: [String: Run] = [:]
    private var finished: [String: AwsLogin.State] = [:]
    private let onChange: @Sendable ([AwsLogin.State]) -> Void
    /// Called once per login that ends in `.done`.
    private let onDone: @Sendable (AwsLogin.State) -> Void

    init(onChange: @escaping @Sendable ([AwsLogin.State]) -> Void,
         onDone: @escaping @Sendable (AwsLogin.State) -> Void) {
        self.onChange = onChange
        self.onDone = onDone
    }

    static let awsCandidates = [
        "/opt/homebrew/bin/aws", "/usr/local/bin/aws",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/aws").path,
        "/usr/bin/aws",
    ]

    func states() -> [AwsLogin.State] {
        Array(runs.values.map(\.state)) + finished.values.filter { s in runs[s.profile] == nil }
    }

    func state(profile: String) -> AwsLogin.State? { runs[profile]?.state ?? finished[profile] }

    /// Starts the flow, or returns the login already in flight for that
    /// profile. `pid` is the session to nudge when it lands.
    func start(profile: String, flow: AwsLogin.Flow, pid: Int?) -> AwsLogin.Reply {
        if let run = runs[profile] { return AwsLogin.Reply(ok: true, state: run.state) }
        guard let aws = Subprocess.find(Self.awsCandidates) else {
            return AwsLogin.Reply(ok: false, error: "aws CLI not found")
        }
        let process = Process()
        // `script -q /dev/null <cmd>`: a pty for the CLI, so its prompt
        // reads the pasted code the way it would from a terminal.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", aws] + AwsLogin.arguments(profile: profile, flow: flow)
        var env = ProcessInfo.processInfo.environment
        env["AWS_PAGER"] = ""
        env["NO_COLOR"] = "1"
        // Relay: the CLI must not open THIS Mac's browser — the phone's
        // web view is the browser. Python's webbrowser honors BROWSER.
        if flow == .relay { env["BROWSER"] = "/usr/bin/true" }
        process.environment = env
        let stdin = Pipe(), out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = out
        let state = AwsLogin.State(profile: profile, flow: flow, startedAt: Date().timeIntervalSince1970, pid: pid)
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { await self.consume(profile: profile, chunk: chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            Task { await self.ended(profile: profile, status: proc.terminationStatus) }
        }
        do {
            try process.run()
        } catch {
            return AwsLogin.Reply(ok: false, error: "could not start aws: \(error.localizedDescription)")
        }
        runs[profile] = Run(process: process, stdin: stdin, state: state)
        finished[profile] = nil
        publish()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AwsLogin.timeout))
            await self?.expire(profile: profile)
        }
        return AwsLogin.Reply(ok: true, state: state)
    }

    /// Writes the pasted code to the waiting `--remote` flow.
    func submit(profile: String, code: String) -> AwsLogin.Reply {
        guard var run = runs[profile] else {
            return AwsLogin.Reply(ok: false, state: finished[profile], error: "no login in flight for \(profile)")
        }
        guard run.state.flow == .remote else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "this flow takes no code")
        }
        guard AwsLogin.isValidCode(code) else { return AwsLogin.Reply(ok: false, state: run.state, error: "invalid code") }
        run.stdin.fileHandleForWriting.write(Data((code + "\n").utf8))
        run.state.phase = .waitingForBrowser
        run.state.message = "code submitted"
        runs[profile] = run
        publish()
        return AwsLogin.Reply(ok: true, state: run.state)
    }

    /// Replays the redirect the phone intercepted against the CLI's own
    /// localhost listener; the CLI then finishes the exchange itself.
    func relay(profile: String, url: String) async -> AwsLogin.Reply {
        guard var run = runs[profile] else {
            return AwsLogin.Reply(ok: false, state: finished[profile], error: "no login in flight for \(profile)")
        }
        guard run.state.flow == .relay || run.state.flow == .local, let port = run.state.callbackPort else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "this flow takes no callback")
        }
        guard AwsLogin.isValidCallback(url, port: port), let target = URL(string: url) else {
            return AwsLogin.Reply(ok: false, state: run.state, error: "not the CLI's callback")
        }
        do {
            _ = try await URLSession.shared.data(from: target)
        } catch {
            return AwsLogin.Reply(ok: false, state: run.state, error: "callback not accepted: \(error.localizedDescription)")
        }
        run.state.message = "callback relayed"
        runs[profile] = run
        publish()
        return AwsLogin.Reply(ok: true, state: run.state)
    }

    private func consume(profile: String, chunk: String) {
        guard var run = runs[profile] else { return }
        run.output += chunk
        if run.output.count > 64 * 1024 { run.output = String(run.output.suffix(32 * 1024)) }
        let prompt = AwsLogin.parseOutput(run.output)
        if let url = prompt.url, run.state.url == nil {
            run.state.url = url
            run.state.phase = .waitingForBrowser
            if run.state.flow == .relay || run.state.flow == .local {
                run.state.callbackPort = AwsLogin.callbackPort(inURL: url)
            }
        }
        if let code = prompt.userCode { run.state.userCode = code }
        if prompt.wantsCode, run.state.message != "code submitted" { run.state.phase = .waitingForCode }
        if prompt.succeeded { run.state.phase = .done }
        if let refusal = prompt.rebindRefusal, run.state.phase != .failed {
            run.stdin.fileHandleForWriting.write(Data("n\n".utf8))
            run.state.phase = .failed
            run.state.message = refusal
        }
        runs[profile] = run
        publish()
    }

    private func ended(profile: String, status: Int32) {
        guard var run = runs[profile] else { return }
        let prompt = AwsLogin.parseOutput(run.output)
        if status == 0 || prompt.succeeded {
            run.state.phase = .done
            run.state.message = "signed in"
        } else if run.state.phase == .failed, run.state.message != nil {
            // Already explained (the declined rebind); the CLI's own last
            // line after a "n" is just its EOF/expired complaint.
        } else {
            run.state.phase = .failed
            let last = run.output.replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("https://") && !$0.lowercased().hasPrefix("enter the authorization") }
            run.state.message = last.map { String($0.prefix(160)) } ?? "aws exited \(status)"
        }
        try? run.stdin.fileHandleForWriting.close()
        runs[profile] = nil
        finished[profile] = run.state
        publish()
        if run.state.phase == .done { onDone(run.state) }
    }

    private func expire(profile: String) {
        guard let run = runs[profile], run.process.isRunning else { return }
        run.process.terminate()
    }

    /// Drops a finished entry (after the session has moved on).
    func forget(profile: String) {
        finished[profile] = nil
        publish()
    }

    private func publish() { onChange(states()) }
}
