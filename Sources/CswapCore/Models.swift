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
public enum JSONValue: Decodable, Equatable, Sendable {
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
}
