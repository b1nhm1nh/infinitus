import ActivityKit
import Foundation
import InfinitusCore

// The two Live Activities' attributes. Their content states are
// InfinitusCore's `WorkingActivityState` / `RevivalActivityState` — the
// same structs the Mac encodes into APNs pushes, so a push and an
// in-app update carry identical JSON. `machine` is fixed for an
// activity's life; the Mac's push-to-start sends it as `attributes`.

struct RevivalActivity: ActivityAttributes {
    typealias ContentState = RevivalActivityState
    var machine: String
}

struct WorkingActivity: ActivityAttributes {
    typealias ContentState = WorkingActivityState
    var machine: String
}
