# Multi-Mac phase 2 — chat and actions through the session's own Mac (#144)

**Goal.** A session that belongs to another paired Mac opens like any
other: its transcript, replies, keys, approvals, checkpoints and images
go to THAT Mac, not the primary. Queued messages (#168) deliver to the
right Mac too.

**Non-goals (phase 3).** Starting a session on another Mac, Siri intents,
the share extension and widgets (primary only), a disk cache for other
Macs' snapshots and tails, Live Activities per Mac.

## What exists (map, 2026-09-06)

- `MirrorModel.others: [OtherMac]` (`pairing: MacPairing`, `snapshot`,
  `fleets`, `status`); one `NetworkFleetMirror(pairing:onLastGood:)` per
  other Mac in the private `otherMirrors` dictionary (`otherMirror(for:)`),
  used only for `latest()`.
- Every action call site hardcodes `NetworkFleetMirror.shared`:
  SessionFeedScreen (sessionTail, parkedTail, sessionInput, checkpoints),
  SessionDetailScreen (sessionInput), CheckpointsScreen (checkpoints,
  restoreCheckpoint, checkpointDiff, sessionInput), FeedThumbnail
  (sessionImage), OutboxDelivery (sessionInput), PastSessionsScreen /
  StartSessionSheet / StartSessionIntent (pastSessions, startSession),
  AwsLoginScreen, Team screens, Settings, CrashReporter, LiveActivities.
- Navigation: `NavigationLink(value: SessionDetail)` →
  `SessionFeedScreen(model:session:)`; `SessionDetailRoute { session }` →
  `SessionDetailScreen`. Other Macs' rows (`SessionsScreen.otherMacSections`)
  are plain, non-tappable, with a "Make this Mac primary…" footer.
- `MobileSessionProgress.byPid` is fed from the primary snapshot only;
  `others[i].snapshot.progressByPid` carries the same shape per Mac.
- `OutboxDelivery` keys items by `macKey = NetworkFleetMirror.parkedKey()`
  (hash of the primary token) and delivers through `.shared`.
- A `.pairing` instance skips Bonjour and rendezvous and has no
  `ParkedCache` — it needs at least one working endpoint.

## Design

### 1. The session's Mac travels with the navigation value

`SessionDetail` stays the primary's navigation value (every existing push
site unchanged). A new value type routes another Mac's session:

```swift
struct OtherSessionRoute: Hashable {
    let macId: String          // MacPairing.id
    let session: SessionDetail
}
```

`SessionsScreen.otherMacSections` rows become `NavigationLink(value:
OtherSessionRoute(macId: other.id, session: row))`; the footer text goes.
`.navigationDestination(for: OtherSessionRoute.self)` pushes
`SessionFeedScreen(model: model, session: route.session, macId: route.macId)`.
`SessionDetailRoute` gains `macId: String?` (default nil) so the detail
screen reached from an other-Mac feed keeps its Mac.

### 2. One environment value carries the mirror

```swift
private struct SessionMirrorKey: EnvironmentKey { static let defaultValue = NetworkFleetMirror.shared }
extension EnvironmentValues { var sessionMirror: NetworkFleetMirror { get set } }
```

`SessionFeedScreen` takes `macId: String? = nil`, resolves
`model.mirror(for: macId)` once, and sets `.environment(\.sessionMirror,
mirror)` on its root. Every `NetworkFleetMirror.shared.` inside
SessionFeedScreen, SessionDetailScreen, CheckpointsScreen and
FeedThumbnail becomes `mirror.` from `@Environment(\.sessionMirror)`.
Screens reached from a primary session keep the default (`.shared`), so
nothing changes for the primary path. `parkedTail` on a `.pairing`
instance returns nil (no cache) — the existing "couldn't reach the Mac"
text stands.

### 3. `MirrorModel` exposes the per-Mac pieces

- `func mirror(for macId: String?) -> NetworkFleetMirror` — `.shared`
  when nil or unknown, else `otherMirror(for: pairing)`.
- `func progress(macId: String?, pid: Int) -> SessionProgress?` — the
  primary's `sessionProgress.byPid[pid]` when nil, else
  `others[…].snapshot?.progressByPid?[pid]` decoded the same way the
  primary's is (`MobileSessionProgress.apply` builds `SessionProgress`
  from `progressByPid` + `tokenRate`; reuse that builder for one entry).
- `func macName(_ macId: String?) -> String?` for the header caption.

SessionFeedScreen reads name/progress through `model.progress(macId:pid:)`
(header, chips) instead of `model.sessionProgress.byPid[...]` directly.
The chat header shows the Mac's name as a caption when `macId != nil`.

### 4. Outbox per Mac

- `NetworkFleetMirror.parkedKey(token:)` — the same 12-hex hash for any
  token; `parkedKey()` calls it with the primary's.
- `OutboxDelivery.macKey(for macId: String?, model:)` → primary key or
  `parkedKey(token: pairing.token)`.
- `SessionFeedScreen` enqueues with that key; `OutboxDelivery.flush(model:)`
  walks the primary and every `others` entry, delivering each key's items
  through `model.mirror(for:)`; the per-Mac reachable edge is the
  primary's `reachableAgain` plus `refreshOthers()` finishing with a
  non-nil snapshot for that Mac (a `othersReachable` hook fired once per
  `refreshOthers` round when any other Mac answered).
- `OutboxItem` is unchanged (it already stores `macKey`).

### 5. Error handling

- A `.pairing` mirror with every endpoint dead throws the same transport
  errors; the feed shows "couldn't reach <Mac name>" (name from
  `macName`), the composer queues as today.
- `makePrimary`/`forgetOther` while an other-Mac feed is open: the
  environment mirror instance stays valid for that screen (the actor is
  retained by the view); on pop, the list is rebuilt from `others`.
- pid collisions across Macs: every per-pid cache in these screens is
  view-local, and `progress(macId:pid:)` is keyed by Mac first, so two
  Macs sharing a pid never mix.

### 6. Testing

No phone unit target: `xcodebuild` (simulator) in CI plus the signed
device build here. Manual: pair two Macs, open a session under the
second Mac's section, read the tail, send a message (lands on that Mac's
terminal), allow a tool, open Checkpoints; put that Mac to sleep, send —
queued under its key; wake it — delivered, primary untouched. InfinitusCore
is untouched, so `swift test` is a no-op gate here.

### 7. Decisions

- Navigation value, not a global "current Mac": two feeds from two Macs
  can sit on the stack at once.
- Environment key over parameter threading: FeedThumbnail and nested
  screens get the mirror without new initializers.
- Other Macs stay Bonjour-less and cache-less in phase 2.
