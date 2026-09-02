import Foundation
import AppKit

/// Runs `cloudflared tunnel run` for a dashboard-managed Cloudflare
/// tunnel (#9 remote access, the stable route): the user creates the
/// tunnel once in Zero Trust (Networks → Tunnels → Cloudflared), points
/// its public hostname at `http://localhost:47824` there, and pastes the
/// tunnel token here. Unlike the quick tunnel the hostname is theirs and
/// never changes, so a phone paired to it survives every restart.
///
/// The token is the only secret and it never touches argv: cloudflared
/// reads `TUNNEL_TOKEN` from the environment. It lives in the keychain
/// (`Keychain.tunnelService`, account = the hostname), never in defaults.
@MainActor
final class NamedTunnel: ObservableObject {
    /// Whether cloudflared has at least one edge connection registered —
    /// the moment the hostname actually answers.
    @Published private(set) var connected = false
    @Published private(set) var status: String?
    /// Set by AppModel so tunnel events land in the popup's event log.
    var log: ((String, String) -> Void)?

    static let hostnameKey = "mirror_named_tunnel_host"
    static let enabledKey = "mirror_named_tunnel_enabled"
    private static let pidKey = "mirror_named_tunnel_pid"

    private var process: Process?
    private var hostname = ""

    init() {
        reapOrphan()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    /// `infinitus.example.com` from whatever the user typed — a pasted
    /// `https://…/` included. Empty when there's nothing usable.
    static func normalizeHostname(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        guard !host.isEmpty, host.contains("."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return "" }
        return host
    }

    /// The phone's endpoint for this route — TLS is Cloudflare's.
    var endpoint: String? { connected ? "https://\(hostname)" : nil }

    static func token(for hostname: String) -> String? {
        Keychain.read(account: hostname, service: Keychain.tunnelService)
    }

    static func setToken(_ token: String, for hostname: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: hostname, service: Keychain.tunnelService) }
        else { _ = Keychain.write(account: hostname, value: trimmed, service: Keychain.tunnelService) }
    }

    func start(hostname: String, token: String) {
        guard process == nil, let binary = QuickTunnel.binaryPath else { return }
        self.hostname = hostname
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--no-autoupdate", "run"]
        var env = ProcessInfo.processInfo.environment
        env["TUNNEL_TOKEN"] = token
        process.environment = env
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n") {
                let line = String(line)
                if line.contains("Registered tunnel connection") {
                    Task { @MainActor [weak self] in self?.registered() }
                } else if line.contains("Unauthorized") || line.contains("invalid tunnel token")
                            || line.contains("Provided Tunnel token is not valid") {
                    Task { @MainActor [weak self] in
                        self?.status = "Cloudflare rejected the tunnel token"
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.ended() }
        }
        do {
            try process.run()
        } catch {
            status = "couldn't start cloudflared: \(error.localizedDescription)"
            return
        }
        self.process = process
        UserDefaults.standard.set(Int(process.processIdentifier), forKey: Self.pidKey)
        status = "connecting \(hostname)…"
    }

    /// Same orphan story as the quick tunnel: a hard kill leaves the
    /// child running, and the pid has to still look like ours.
    private func reapOrphan() {
        let defaults = UserDefaults.standard
        let pid = defaults.integer(forKey: Self.pidKey)
        defaults.removeObject(forKey: Self.pidKey)
        guard pid > 1, let command = QuickTunnel.commandLine(of: pid),
              command.contains("cloudflared"), command.hasSuffix("run") else { return }
        kill(pid_t(pid), SIGTERM)
    }

    func stop() {
        guard let process else { return }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        self.process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        if process.isRunning { process.terminate() }
        connected = false
        status = nil
    }

    private func registered() {
        guard !connected else { return }
        connected = true
        status = "https://\(hostname)"
        log?("🌐", "named tunnel up at https://\(hostname)")
    }

    private func ended() {
        guard process != nil else { return }
        process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        connected = false
        status = "the named tunnel stopped"
        log?("⚠️", "named tunnel stopped")
    }
}
