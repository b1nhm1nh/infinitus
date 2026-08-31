import Foundation

// MARK: - cswap list --json (the display feed)
//
// Field names mirror the schema-v1 camelCase payloads from
// claude_swap/json_output.py verbatim, so JSONDecoder needs no key strategy.
// Optionality mirrors the emitter: sub-keys appear only when the API sent
// them, and `usage` is null for sentinel rows (no credentials, expired…).

public struct AccountList: Decodable, Sendable {
    public let schemaVersion: Int
    public let activeAccountNumber: Int?
    public let accounts: [Account]
    /// Advisory: the account the auto-switcher would likely pick next.
    public let nextCandidate: Int?
    /// Advisory, only when nextCandidate is absent: every account is at
    /// a limit — this one's last maxed window resets soonest.
    public let nextRecovery: NextRecovery?
    /// Live Claude Code sessions on this machine (they all ride the
    /// active account's credential). busy = mid-turn right now.
    public let liveSessions: LiveSessions?
}

public struct NextRecovery: Decodable, Sendable {
    public let number: Int
    /// ISO-8601 instant the account is fully usable again.
    public let at: String
}

public struct LiveSessions: Decodable, Sendable {
    public let busy: Int
    public let total: Int
    /// Additive breakdown (an older engine omits them; the chip tooltip
    /// falls back to busy/total): "unknown" is a record with no status —
    /// e.g. sdk-cli sessions. busy+idle+waiting+shell+unknown == total.
    public let idle: Int?
    public let waiting: Int?
    public let shell: Int?
    public let unknown: Int?
    /// Additive per-session detail (busy first, capped engine-side).
    public let sessions: [SessionDetail]?
}

public struct SessionDetail: Decodable, Sendable, Hashable {
    public let pid: Int
    public let cwd: String
    public let status: String
    public let kind: String
    public let startedAt: Double   // epoch milliseconds
}

public struct Account: Decodable, Sendable {
    public let number: Int
    public let email: String
    public let organizationName: String
    public let organizationUuid: String
    public let isOrganization: Bool
    public let active: Bool
    public let usageStatus: String
    public let usage: Usage?
    public let alias: String?
    /// One-emoji display icon (`cswap icon`); additive field, may be absent.
    public let icon: String?
    /// Claude subscription tier ("Max 20x", "Pro"); additive, may be absent.
    public let plan: String?
    public let disabled: Bool?
    public let usageFetchedAt: String?
    public let usageAgeSeconds: Double?
    // Display-grade last-good data served when the live fetch failed.
    public let lastGoodUsage: Usage?
    public let lastGoodFetchedAt: String?
    public let lastGoodAgeSeconds: Double?
}

public struct Usage: Decodable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let scoped: [UsageWindow]?
    public let spend: Spend?
}

public struct UsageWindow: Decodable, Sendable {
    public let pct: Double
    public let resetsAt: String?
    public let countdown: String?
    public let clock: String?
    /// Model display name — present on `scoped` windows only.
    public let name: String?
    // Weekly pace fields (issue #125); JSON-only, wide error bars.
    public let expectedPct: Double?
    public let aheadOfPace: Bool?
    public let projectedExhaustionAt: String?
    public let willLastToReset: Bool?
}

public struct Spend: Decodable, Sendable {
    public let used: Double
    public let limit: Double
    public let pct: Double
    public let currency: String
    public let resetsAt: String?
    public let countdown: String?
    public let clock: String?
}

// MARK: - cswap config list --json (the spec-driven settings feed)

public struct ConfigList: Decodable, Sendable {
    public let schemaVersion: Int
    public let path: String
    public let settings: [SettingEntry]
}

/// One SETTING_SPECS row. The GUI renders a widget from `kind` +
/// `lo`/`hi`/`choices` and never hand-wires per-key controls — the whole
/// point of the metadata export (spec §3.1).
public struct SettingEntry: Decodable, Sendable {
    public let key: String
    public let value: JSONValue
    public let isSet: Bool
    public let kind: String
    public let help: String
    public let defaultValue: JSONValue
    public let lo: Double?
    public let hi: Double?
    public let choices: [String]?

    enum CodingKeys: String, CodingKey {
        case key, value, isSet, kind, help, lo, hi, choices
        case defaultValue = "default"
    }
}

/// Settings values are heterogeneous (bool / number / string), so they land
/// in a closed enum instead of Any.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// `cswap usage --json` — estimated per-account token spend. The dollar
/// figures are API-list-price estimates (the report's caveats say so);
/// render them as estimates, never as a bill.
public struct UsageReport: Decodable, Sendable {
    public let schemaVersion: Int
    public let days: Int
    public let estimatedTotalUSD: Double
    public let priceTable: PriceTable
    public let accounts: [UsageBucket]
    public let unattributed: UsageBucket?
    public let unpricedTokens: Int?
    public let caveats: [String]
    /// Per-day, per-account spend rows for the charts. Optional: an older
    /// installed CLI simply yields no charts, never a decode failure.
    public let daily: [DailySlice]?

    public struct PriceTable: Decodable, Sendable {
        public let source: String
        public let date: String
    }

    public struct UsageBucket: Decodable, Sendable {
        public let number: Int?
        public let email: String?
        public let alias: String?
        public let estimatedUSD: Double
        public let messages: Int
        public let input: Int
        public let output: Int
        public let cacheRead: Int
        public let cacheWrite: Int
        public let models: [ModelSlice]
    }

    public struct DailySlice: Decodable, Sendable {
        public let date: String        // "YYYY-MM-DD", local time
        public let account: Int?       // nil = unattributed
        public let estimatedUSD: Double
        public let messages: Int
    }

    public struct ModelSlice: Decodable, Sendable {
        public let model: String
        public let estimatedUSD: Double
        public let messages: Int
    }
}

public enum TokenFormat {
    /// Compact token count: 950, 12.3k, 4.5M, 1.2B.
    public static func compact(_ n: Int) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "k")]
        for (div, suffix) in units where Double(n) >= div {
            return String(format: "%.1f%@", Double(n) / div, suffix)
        }
        return String(n)
    }
}

/// Gauge math for the gamified account rows (backlog item 8) — the WoW
/// statusline's 8-cell bar, recomputed here because the app renders it in
/// SwiftUI rather than ANSI. Pure so it can be tested without a view.
public enum GaugeMath {
    public static let cells = 8

    /// How many of the 8 cells are filled for a remaining-percentage,
    /// rounded to nearest (the statusline's `(pct*W + 50)/100`).
    public static func filled(_ pct: Double) -> Int {
        let clamped = Int(max(0, min(100, pct)))
        return (clamped * cells + 50) / 100
    }

    /// Remaining percentage from a used percentage — HP/MP semantics:
    /// a fresh account shows a full bar.
    public static func remaining(usedPct: Double) -> Double {
        max(0, min(100, 100 - usedPct))
    }

    /// Pace-fire intensity 0…1: how far usage runs ahead of the
    /// clock's expectation, saturating at +30 points. Zero unless the
    /// engine says aheadOfPace (expectedPct alone can be behind pace).
    public static func burnHeat(usedPct: Double, expectedPct: Double?,
                                ahead: Bool?) -> Double {
        guard ahead == true, let expected = expectedPct else { return 0 }
        return max(0, min(1, (usedPct - expected) / 30))
    }
}

/// `cswap history --json` — recent account switches, newest first. The
/// engine parses its own log; frontends never scrape the file.
public struct SwitchHistoryList: Decodable, Sendable {
    public struct Switch: Decodable, Sendable {
        public let from: Int
        public let to: Int
        public let at: String
    }
    public let schemaVersion: Int
    public let switches: [Switch]
    public let logPath: String
}
