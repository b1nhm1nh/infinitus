import SwiftUI
import Foundation

/// OpenAI Codex account slots, Swift-native (2026-08-30). The Python
/// `cswap codex` v1 was reverted the same day — multi-engine belongs in
/// Limitless, not the Claude engine (user decision). Same mechanism:
/// $CODEX_HOME/auth.json (file-mode credential store, format verified
/// against openai/codex fixtures) snapshotted into slots and swapped
/// whole. Slots live in App Support/Limitless/engines/codex/<n>/.
/// v1 scope: add / switch / list. No refresh, no usage, no auto-switch.
@MainActor
final class CodexEngineModel: ObservableObject {
    struct Slot: Identifiable {
        let id: String
        let email: String?
        let plan: String?
        let mode: String        // "chatgpt" | "api-key" | "?"
        let active: Bool
    }

    @Published var slots: [Slot] = []
    @Published var authPresent = false
    @Published var status: String?

    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    private var authURL: URL { Self.codexHome.appendingPathComponent("auth.json") }

    private var storeRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Limitless/engines/codex")
    }

    private var stateURL: URL { storeRoot.appendingPathComponent("state.json") }

    func reload() {
        let fm = FileManager.default
        authPresent = fm.fileExists(atPath: authURL.path)
        let active = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["active"]
        let names = ((try? fm.contentsOfDirectory(atPath: storeRoot.path)) ?? [])
            .filter { fm.fileExists(atPath: storeRoot.appendingPathComponent("\($0)/auth.json").path) }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
        slots = names.map { name in
            let claims = Self.claims(
                at: storeRoot.appendingPathComponent("\(name)/auth.json"))
            return Slot(id: name,
                        email: claims.email,
                        plan: claims.plan,
                        mode: claims.mode,
                        active: name == active)
        }
    }

    /// Snapshot the live login as a slot (and mark it active — the live
    /// file and the slot are identical at this instant).
    func addCurrent() {
        guard authPresent else {
            status = "no Codex login found — run `codex login` first"
            return
        }
        let next = ((slots.compactMap { Int($0.id) }.max()) ?? 0) + 1
        do {
            try copyAuth(from: authURL, toSlot: String(next))
            try writeActive(String(next))
            status = "saved current login as slot \(next)"
            reload()
        } catch { status = "add failed: \(error.localizedDescription)" }
    }

    func switchTo(_ slot: String) {
        let slotAuth = storeRoot.appendingPathComponent("\(slot)/auth.json")
        do {
            // Save the live login back to its slot first — Codex refreshes
            // tokens in place and the stored copy goes stale.
            if let active = slots.first(where: \.active)?.id, active != slot,
               FileManager.default.fileExists(atPath: authURL.path) {
                try copyAuth(from: authURL, toSlot: active)
            }
            try FileManager.default.createDirectory(
                at: authURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try Data(contentsOf: slotAuth)
            try data.write(to: authURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: authURL.path)
            try writeActive(slot)
            status = codexRunning()
                ? "switched to slot \(slot) — a codex process is running and may overwrite the login when it refreshes"
                : "switched to slot \(slot)"
            reload()
        } catch { status = "switch failed: \(error.localizedDescription)" }
    }

    func remove(_ slot: String) {
        try? FileManager.default.removeItem(
            at: storeRoot.appendingPathComponent(slot))
        status = "removed slot \(slot)"
        reload()
    }

    private func copyAuth(from src: URL, toSlot slot: String) throws {
        let dir = storeRoot.appendingPathComponent(slot)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: src)
        try data.write(to: dst)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    private func writeActive(_ slot: String) throws {
        try FileManager.default.createDirectory(
            at: storeRoot, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["active": slot], options: [.prettyPrinted])
        try data.write(to: stateURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func codexRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "codex"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Identity labels from the id_token's unverified claims — the token
    /// is already ours; never store or show token material itself.
    private static func claims(at url: URL) -> (email: String?, plan: String?, mode: String) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil, "?") }
        if obj["OPENAI_API_KEY"] as? String != nil,
           (obj["tokens"] as? [String: Any])?["id_token"] == nil {
            return (nil, nil, "api-key")
        }
        guard let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else { return (nil, nil, "?") }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil, "chatgpt") }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return (nil, nil, "chatgpt") }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return (claims["email"] as? String,
                auth?["chatgpt_plan_type"] as? String,
                "chatgpt")
    }
}
