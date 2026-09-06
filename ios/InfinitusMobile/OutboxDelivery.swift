import Foundation
import InfinitusCore
import UIKit
import UserNotifications

/// #168: the phone side of the outbox — where it lives on disk, how an
/// item is sent, and the notification when one lands while the app is
/// not on screen (the Mac pushes its own when the app is closed).
enum OutboxDelivery {
    static let outbox: Outbox = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Outbox(root: support.appendingPathComponent("outbox"))
    }()

    static var macKey: String { NetworkFleetMirror.parkedKey() }

    /// `reachableAgain` and the first-successful-load trigger can fire
    /// within moments of each other — single-flight so a second call
    /// doesn't re-send an item the first call already marked in flight.
    @MainActor private static var flushing = false

    static func flush() async {
        let canRun = await MainActor.run { () -> Bool in
            guard !flushing else { return false }
            flushing = true
            return true
        }
        guard canRun else { return }
        defer { Task { @MainActor in flushing = false } }

        // Names and text by id, captured before the flush — a delivered
        // item's file is gone by the time `results` comes back.
        let items = outbox.items(macKey: macKey)
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.sessionName) })
        let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.request.text) })
        let results = await outbox.flush(macKey: macKey, deliver: deliver)
        let delivered = results.filter { $0.delivery == .delivered }
        guard !delivered.isEmpty else { return }
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        if !active {
            for result in delivered {
                let content = UNMutableNotificationContent()
                content.title = names[result.id].map { "Delivered to \($0)" } ?? "Delivered"
                content.body = texts[result.id].map { String($0.prefix(80)) } ?? "Your queued message reached the session."
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "outbox-\(result.id.uuidString)", content: content, trigger: nil))
            }
        }
    }

    static func deliver(_ item: OutboxItem) async -> Outbox.Delivery {
        do {
            let reply = try await NetworkFleetMirror.shared.sessionInput(pid: item.pid, request: item.request)
            switch reply.outcome {
            case "delivered", "running", "captured": return .delivered
            case "rejected" where reply.detail == "session ended": return .ended
            default: return .refused(reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            }
        } catch MirrorTransportError.http(let code) {
            // The Mac answered — a rotated pairing token, most likely. Not
            // "gone", so the item must not retry forever as queued.
            return .refused("HTTP \(code)")
        } catch {
            return .transport
        }
    }
}
