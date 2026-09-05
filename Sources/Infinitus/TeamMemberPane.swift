import SwiftUI
import InfinitusCore

/// Placeholder for Task 5 (a teammate's Stats tiles, session index and
/// transcripts). TeamPane's "Detail" link pushes it; Task 5 replaces the
/// body, keeping this initializer.
struct TeamMemberPane: View {
    let team: TeamModel
    let kid: String

    var body: some View { Text(kid) }
}
