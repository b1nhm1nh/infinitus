import Foundation
import InfinitusCore
import WidgetKit
import os

/// What the home-screen and lock-screen widgets draw (#80): the same
/// themed states the Live Activities use, handed over through the shared
/// keychain item (no App Group, see SharedKeychain). The app writes it
/// on every refresh that changed something and reloads the timelines;
/// the widget's provider reads it.
enum WidgetBridge {
    struct Payload: Codable, Equatable {
        var working: WorkingActivityState?
        var revival: RevivalActivityState?
        var machine: String
        var capturedAt: Date
    }

    static let service = "run.infinitus.widget"
    static let account = "fleet"
    private static let log = Logger(subsystem: "run.infinitus.mobile", category: "widgets")
    private static var lastWritten: Payload?

    @MainActor
    static func publish(_ payload: Payload) {
        guard payload != lastWritten else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        let status = SharedKeychain.write(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            if lastWritten == nil { log.error("widget bridge write failed: \(status)") }
            return
        }
        lastWritten = payload
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func load() -> Payload? {
        guard let data = SharedKeychain.read(service: service, account: account) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }
}
