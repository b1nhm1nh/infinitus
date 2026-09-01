import Foundation
import CswapCore

/// Reads the fleet mirror a Mac already captured (#9 phase 1's
/// `FleetMirror` seam) and republishes it as view-ready state.
@MainActor
final class MirrorModel: ObservableObject {
    @Published private(set) var snapshot: MirrorSnapshot?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var nextRecovery: NextRecovery?
    @Published private(set) var nextCandidate: Int?
    @Published private(set) var error: String?

    private let mirror: FleetMirror

    init(mirror: FleetMirror? = nil) {
        self.mirror = mirror ?? Self.makeMirror()
    }

    /// `INFINITUS_MIRROR_PATH` lets a simulator point at the Mac's live
    /// export; otherwise the app keeps its own copy in Documents.
    private static func makeMirror() -> FleetMirror {
        if let path = ProcessInfo.processInfo.environment["INFINITUS_MIRROR_PATH"] {
            return FileFleetMirror(url: URL(fileURLWithPath: path))
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return FileFleetMirror(url: documents.appendingPathComponent("mirror-snapshot.json"))
    }

    /// Pure decode of the mirror's `listJSON` payload — same `AccountList`
    /// model the mac app and tray decode, plain `JSONDecoder` (no date
    /// strategy; the model's date-bearing fields are raw ISO strings).
    static func decodeList(_ data: Data) -> AccountList? {
        try? JSONDecoder().decode(AccountList.self, from: data)
    }

    func refresh() async {
        do {
            guard let snapshot = try await mirror.latest() else {
                self.snapshot = nil
                error = nil
                return
            }
            guard let list = Self.decodeList(snapshot.listJSON) else {
                error = "couldn't read the mirrored fleet data"
                return
            }
            self.snapshot = snapshot
            let corrected = RecoveryMath.corrected(engine: list.nextRecovery, accounts: list.accounts)
            accounts = DisplayOrder.sort(list.accounts, active: list.activeAccountNumber,
                                         next: list.nextCandidate)
            nextRecovery = corrected
            nextCandidate = list.nextCandidate
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
