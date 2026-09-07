import ActivityKit
import Foundation
import InfinitusCore

// The two Live Activities' attributes. Their content states are
// InfinitusCore's `WorkingActivityState` / `RevivalActivityState` — the
// same structs the Mac encodes into APNs pushes, so a push and an
// in-app update carry identical JSON. `machine` is fixed for an
// activity's life; the Mac's push-to-start sends it as `attributes`.

/// A card belongs to one Mac (#144): `machine` is the Mac's name.
protocol MacCard: ActivityAttributes {
    var machine: String { get }
}

struct RevivalActivity: MacCard {
    typealias ContentState = RevivalActivityState
    var machine: String
}

struct WorkingActivity: MacCard {
    typealias ContentState = WorkingActivityState
    var machine: String
}
