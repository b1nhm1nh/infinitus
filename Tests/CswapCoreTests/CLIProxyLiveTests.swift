import XCTest
@testable import CswapCore

/// Live smoke against a real CLIProxyAPI — skipped unless
/// INFINITUS_LIVE_PROXY_KEY is set (the dev proxy on this machine,
/// docs/research/multi-engine.md §6). Prints the mapped fleets so a
/// drift between the installed proxy and the fixtures is visible.
final class CLIProxyLiveTests: XCTestCase {
    func testLiveSnapshot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["INFINITUS_LIVE_PROXY_KEY"], !key.isEmpty else {
            throw XCTSkip("INFINITUS_LIVE_PROXY_KEY not set")
        }
        let base = URL(string: env["INFINITUS_LIVE_PROXY_URL"] ?? "http://127.0.0.1:8317")!
        let engine = CLIProxyEngine(baseURL: base, managementKey: key)
        let probe = try await engine.probe()
        print("LIVE probe: \(probe)")
        let fleets = try await engine.snapshot()
        for f in fleets {
            print("LIVE fleet \(f.engineID)/\(f.provider) active=\(String(describing: f.activeNumber)) next=\(String(describing: f.nextCandidate))")
            for a in f.accounts {
                print("  #\(a.number) \(a.email) status=\(a.usageStatus) disabled=\(String(describing: a.disabled)) usage=\(a.usage.map { "5h \($0.fiveHour?.pct ?? -1) 7d \($0.sevenDay?.pct ?? -1)" } ?? "nil") plan=\(a.plan ?? "-") org=\(a.organizationName)")
            }
        }
        XCTAssertFalse(fleets.isEmpty)
        // Raw relay for the first credential: what did Anthropic answer?
        let (_, data) = try await engine.rawGet("auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        if let first = files.first {
            let env = try await engine.apiCall(authIndex: first.authIndex ?? first.id ?? first.name,
                                               url: "https://api.anthropic.com/api/oauth/usage")
            print("LIVE api-call status=\(env.statusCode) body=\(env.body.prefix(200))")
        }
    }
}
