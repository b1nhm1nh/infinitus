import SwiftUI
import AppKit

/// Claude/Anthropic service health from the public Statuspage API.
/// Refreshed when the popup opens (10-minute cache) — never on a timer,
/// the popup is the only consumer.
@MainActor
final class ServiceStatusModel: ObservableObject {
    static let shared = ServiceStatusModel()

    @Published var indicator: String?      // none | minor | major | critical
    @Published var descriptionText: String?
    private var fetchedAt: Date?
    private static let api = URL(string: "https://status.anthropic.com/api/v2/status.json")!
    private static let page = URL(string: "https://status.anthropic.com")!

    func refreshIfStale() {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 600 { return }
        Task {
            struct Payload: Decodable {
                struct Status: Decodable { let indicator: String; let description: String }
                let status: Status
            }
            guard let (data, _) = try? await URLSession.shared.data(from: Self.api),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else { return }
            indicator = payload.status.indicator
            descriptionText = payload.status.description
            fetchedAt = Date()
        }
    }

    func openPage() { NSWorkspace.shared.open(Self.page) }

    var color: Color {
        switch indicator {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        case "critical": return .red
        default: return .gray
        }
    }

    var shortText: String {
        switch indicator {
        case "none": return "claude ok"
        case "minor": return "minor outage"
        case "major": return "major outage"
        case "critical": return "critical outage"
        default: return "status"
        }
    }

    var helpText: String {
        (descriptionText ?? "Claude service status unknown")
            + " — click to open the status page"
    }
}
