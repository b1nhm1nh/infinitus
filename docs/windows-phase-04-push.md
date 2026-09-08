# Phase 04 — push for Windows-hosted events

## Goal

Decide, honestly, what a Windows box can do about lock-screen
notifications for events it hosts. The short answer verified below: the
daemon **cannot** push to the phone itself — APNs requires an Apple
`.p8` the Mac holds in its keychain and a signing path Windows does not
have. This phase scopes the one real option (relay through a paired Mac)
and says plainly what is out of scope.

## Non-goals

- **No APNs client on Windows.** Not deferred, not hard — impossible
  with the credentials a Windows box can obtain. See Current state.
- No new phone-side push transport, no third-party push service, no
  Windows-hosted Live Activity.
- No change to how the Mac pushes.

## Current state

### How the Mac pushes

- `Sources/InfinitusCore/LiveActivityPush.swift:69-71` —
  `host(sandbox:)` → `api.sandbox.push.apple.com` /
  `api.push.apple.com`; `:73-75` the endpoint
  `https://<host>/3/device/<token>`. **Straight to Apple, no relay.**
- `:55-56` — `bundleID = "run.infinitus.mobile"`,
  `topic = bundleID + ".push-type.liveactivity"`.
- `:78-113` — `updatePayload` / `endPayload` / `startPayload`
  (push-to-start) / `alertPayload`.
- `:139-149` — `APNsJWT.Credentials { keyID, teamID, privateKeyPEM }`.
- **`:153-169` — the signing path**: `P256.Signing.PrivateKey(pemRepresentation:)`,
  ES256 JWT, header `{alg,kid}`, claims `{iss=teamID,iat}`. Fenced
  `#if canImport(CryptoKit)`, and **`:166-168` is `#else throw
  Failure.unsupported` — there is no non-Apple path.**
- `:172` — `lifetime = 50*60`, the JWT re-mint budget.
- `:63-65` — `isDeadToken`: 410 / `BadDeviceToken` /
  `DeviceTokenNotForTopic` → drop the registration.
- `Sources/Infinitus/LiveActivityPusher.swift:215-222` — `bearer()`:
  cached JWT, else keychain read + mint; `:231-242` the request
  (`authorization`, `apns-topic`, `apns-push-type`, `apns-priority: 10`);
  `:244-265` responses, clearing the JWT on
  `InvalidProviderToken`/`ExpiredProviderToken` (`:260-262`).
- Credential storage: `Sources/Infinitus/Keychain.swift:15` —
  `apnsService = "run.infinitus.apns"`, account = key id; `:29-56`
  `SecItemCopyMatching`/`SecItemAdd`, **macOS Security framework only**.
  `LiveActivityPusher.swift:49-72` `storeKey(pem:)` validates and writes
  it; `:15-20`, `:35-36` keep key id and team id in `UserDefaults`, and
  only the PEM in the keychain. UI entry:
  `Sources/Infinitus/SyncPane.swift:274-278`.
- Token shape: `LiveActivityPush.swift:15-52` —
  `ActivityPushRegistration`, **per-device and per-activity-kind**,
  `slot = "<deviceId>/<kind>"` (`:51`), kinds at `:16-24` including
  `alert`. `LiveActivityPusher.swift:76-88` — one slot per device+kind.
- The **signing key is per-team/per-app**: one `.p8` signs for every
  device.
- The phone already fans tokens out:
  `ios/InfinitusMobile/LiveActivities.swift:256-274` posts each token to
  the primary Mac **and every other reachable paired Mac**; `:278-281`
  `resendPhoneTokens` on reconnect. So multiple Macs can each hold the
  same tokens — but each needs its own `.p8` in its own keychain.

### Where Windows discards the token

- `MirrorTransport.swift:80` — `activityTokenPath = "/activities/token"`.
- Mac accepts: `Sources/Infinitus/MirrorServer.swift:994-1004` — decodes
  `ActivityPushRegistration`, `activityTokens.call(...)`, 200
  `{"ok":true}`; the sink is `MirrorActivityTokenBox`
  (`MirrorServer.swift:82-94`), wired at `:425`.
- **`windows/Sources/InfinitusWin/Routes.swift:51-56` — the discard.**
  The comment reads "Windows has no APNs path, so accept and discard
  rather than 404 on every launch", then returns `{}`. No storage, no
  forwarding. Documented at `windows/README.md:545`;
  `windows/smoke.ps1:220-228` asserts only 2xx, not persistence.
- The Linux tray has no such route at all
  (`Sources/InfinitusTray/InfinitusTray.swift:641-670` mounts snapshot,
  tail, input only), and `LiveActivityPush.swift:137-138` notes it
  "pushes nothing (parity pending)".

### Is the `.p8` reachable from Windows? No.

- `*.p8` anywhere in the repo: **zero hits**, tracked or ignored — never
  present.
- `apnsService` appears only at `Keychain.swift:15` and
  `LiveActivityPusher.swift:42/53/69/217`. The PEM lives **only** in the
  macOS keychain of the Mac it was pasted into; never on disk, never in
  defaults (`LiveActivityPusher.swift:8-9`: "never argv, never shown").
- `tools/signing-wizard.sh:226` — "The .p8 downloads exactly once";
  Apple serves it a single time. `:350-358` also warns the APNs key is a
  **different** key from the notarization one — so the
  `NOTARY_KEY_BASE64` secret in `.github/workflows/release.yml:58,61`
  (`docs/RELEASING.md:46`) is **not** usable for pushes.
- And even handed the PEM, Windows could not sign:
  `LiveActivityPush.swift:156` is the only auth path and `:166-168`
  hard-fails without CryptoKit. Windows has neither CryptoKit nor
  Security.framework.

### Does the phone actually need push for the live feed? No — only when backgrounded.

- `Sources/InfinitusCore/SessionFeed.swift:224-239` —
  `waitForChange(pid:claudeDir:since:wait:poll:)`, blocking long-poll,
  0.3 s stamp re-poll; `:216-222` `stamp()` = `size-mtime-status`.
  `MirrorTransport.swift:87-92` — `since`/`wait`, `tailWaitMax = 25`.
- Windows already serves it:
  `windows/Sources/InfinitusWin/Routes.swift:64-70` calls
  `waitForChange`; `:62-63` notes blocking is fine because the listener
  is one thread per connection.
- Phone side: `ios/InfinitusMobile/NetworkFleetMirror.swift:408-429`
  (`?n=&since=&wait=`, timeout `wait + 10`);
  `ios/InfinitusMobile/SessionFeedScreen.swift:314-338` the loop,
  `:546-552` passing `feed.stamp`.
- **So the live transcript needs no push at all** while the screen is
  foregrounded. The loop dies on backgrounding
  (`SessionFeedScreen.swift:55`, `:338`) — which is exactly and only the
  case APNs covers.

### Is there a "route push through the Mac" surface today? No.

Full route inventory — `MirrorTransport.swift:16, 18, 29, 43, 53, 69,
80, 82, 85`: `/snapshot`, `/sessions/<pid>/tail`,
`/sessions/<pid>/images/<id>`, `/sessions/<pid>/checkpoints`(+`/<n>/<action>`),
`/sessions/<pid>/input`, `/activities/token`, `/crashes`, `/app/update`.
**Every one is phone→Mac. No route accepts a push request from another
host**, and there is no host-to-host relay anywhere in
`MirrorTransport.swift`. `MirrorActivityTokenBox`
(`MirrorServer.swift:82-94`) is reachable only via the phone's own POST.
(The unrelated `PushTriggers` at
`Sources/InfinitusTray/InfinitusTray.swift:568-605` shells `cswap notify
push` — a local notifier, not APNs, and engine-coupled.)

## Design

Three options, graded. **Recommendation: ship A, and stop.**

### Option A (recommended, S) — be honest at the wire, and notify locally

Two small, self-contained pieces of real value:

1. **Stop lying by omission at `/activities/token`.** Keep returning
   2xx (a 404 on every phone launch would be worse —
   `Routes.swift:51-56`'s reasoning stands), but answer with a body the
   phone can read: an explicit "this host cannot push" capability flag.
   The phone then knows not to expect lock-screen delivery from this
   host, instead of silently never getting it. This needs a phone-side
   read to be useful, so it is only worth doing together with a
   one-line phone change — scope it as such or skip it.
2. **Notify on the box instead.** The event the user misses is on their
   Windows desktop; a Windows toast is the honest local answer and the
   tray already has the surface —
   `windows/Sources/InfinitusTrayWin/TrayNotify.swift`. Wire the
   events that would have pushed (limit stop, session finished, a
   granted team command answered) to a tray notification. This is
   real, cheap, and needs no Apple anything.

Cost: S. No new credentials, no new trust relationship, no Apple keys.

### Option B (possible, M, needs a Mac) — relay through the paired Mac

The only path to an actual phone push. Shape:

- The Mac grows a **new** route that accepts a push request from another
  host — nothing like it exists today, so this is a wire-contract
  addition on the Mac, authenticated as its own thing.
- The Windows daemon stores the tokens it currently discards
  (`Routes.swift:51-56`) and forwards a push request to a configured
  Mac, which signs with its keychain `.p8` and posts to Apple.

Why it is unattractive despite being possible:

- It reintroduces the dependency the Windows port exists to avoid — the
  `windows-remote` plan rejected an SSH-relay design precisely because
  it "needs a Mac up 24/7 as a relay"
  (`docs/plan-windows/README.md`, the options table, on branch
  `windows-remote`). A push relay has the same defect.
- It is a **new inbound authenticated route on the Mac** whose payload
  causes the Mac to send a push on another machine's word. That is a
  meaningful new trust surface on the machine holding the signing key,
  and it must be scoped so a Windows box can only trigger pushes for
  devices already paired to that Mac — otherwise the relay is an
  open push proxy.
- The phone already posts its tokens to **every reachable paired Mac**
  (`LiveActivities.swift:256-274`), so in the common
  "Mac and Windows box on one desk" case, **the Mac can already push
  for events it can see** — the gap is only events it cannot see, i.e.
  Windows-hosted sessions.

If it is ever built, that framing is the design: the Mac is the pusher
for the fleet, and Windows hands it *facts about Windows sessions*,
which is closer to a snapshot-sharing feature than a push feature.

### Option C (rejected) — Windows-native APNs

Rejected on evidence, not preference: no `.p8` obtainable
(never in the repo; Apple serves it once; it lives in one Mac's
keychain), and `LiveActivityPush.swift:166-168` has no non-CryptoKit
signing path. Even a hand-rolled ES256 over swift-crypto (which *is*
available on Windows — `Package.swift:123` already depends on
swift-crypto and `P256` is in it) would not help, because **the key
itself cannot legitimately reach the Windows box.** Asking a user to
copy a private signing key onto a second machine to work around this is
a worse security posture than not having the feature, and it conflicts
with the repo's own handling of that key (never on disk, never shown).

## Test plan

- `swift build --product infinitus-win`, then `--product
  infinitus-tray-win` (one per invocation); `swift test` under
  `. .\windows\env.ps1`, no `INCLUDE`/`LIB`
  (`windows/env.ps1:9-12`).
- Option A: a `Routes` test asserting `/activities/token` still answers
  2xx and now carries the capability flag — extend the existing
  route-shape tests in `windows/Tests/InfinitusWinTests/`.
  `windows/smoke.ps1:220-228` already asserts the 2xx and **must stay
  green** — do not change the status code.
- Toast wiring: assert the notification is *composed* (a pure
  string/decision test); do not assert Windows actually displayed it.
- **XCTSkip is not the tool here** — there is nothing platform-gated to
  skip. `Sources/InfinitusCore/LiveActivityPush.swift`'s payload
  builders (`:78-113`) are pure and already testable everywhere; if any
  of their tests are currently Mac-only, note that the *signing* tests
  must stay fenced (`#if canImport(CryptoKit)`), not the payload ones.
- If Option B is ever attempted: no test can prove an end-to-end push
  without a real device and a real key. State that up front so nobody
  designs a fake one.

## Acceptance criteria

- [ ] The docs say plainly, in `windows/README.md`, that a Windows host
      cannot push to the phone and why (Apple key, Mac keychain) — the
      current "accepted and discarded" line (`:545`) is replaced with the
      reason, not just the behaviour.
- [ ] `/activities/token` still returns 2xx; `windows/smoke.ps1`
      (`:220-228`) stays green.
- [ ] The events that would have pushed raise a Windows tray
      notification instead.
- [ ] No `.p8`, no APNs endpoint, no signing code lands under
      `windows/`.
- [ ] The relay option is written down as a decision with its trust
      cost, so it is not re-litigated from scratch.
- [ ] No new polling and no new timer; idle CPU unchanged.

## Parallelization notes

**Owns exclusively:** the `/activities/token` handler region of
`windows/Sources/InfinitusWin/Routes.swift` (`:51-56`),
`windows/Sources/InfinitusTrayWin/TrayNotify.swift`, and the
`windows/README.md` push section (reported, not edited — see phase 01's
README note).

**Conflicts with phase 03:** both touch `Routes.swift` (03 refactors the
delivery call at `:134-142`) and both may mount something in `serve`
(`InfinitusWinMain.swift:320-329`). Different regions of the same files —
mergeable, but not by two agents at once. Sequence them, 03 first.

**Conflicts with phase 05:** `Routes.swift:86` (`keys: false`) is 05's
line; this phase must not touch the tail response.

**Safe beside:** phases 01, 02, 06, 07.

## Risks + open questions

- The main risk is **scope creep into Option B**. An implementer who
  reads "push" as a feature request will build the relay. The doc must
  be read as: A is the deliverable, B is a recorded decision.
- The capability-flag half of A is only useful with a phone change; if
  the phone is out of scope for this batch, ship the toast half alone
  rather than adding a flag nobody reads.
- Open: which events deserve a toast? Limit stop is obvious; "session
  finished" may be noise on a box with seven sessions
  (`windows/README.md:266-316` shows seven live). Needs a knob, and
  the knob must default to quiet.
- Open: does `TrayNotify` survive the daemon running without the tray?
  `infinitus-win serve` and `infinitus-tray-win` are separate products
  (`Package.swift:92`, `:110`); a daemon-only user gets no toast unless
  the daemon can raise one itself.
- Open (Option B only): would the Mac relay need the phone's tokens at
  all, or would the Windows box simply tell the Mac "session X on host Y
  stopped" and let the Mac's existing pusher decide? The latter is
  smaller and leaks less.

## Estimated size

**S** for Option A as scoped. **M+** for Option B, and it should not be
attempted without an explicit ask — it adds a permanent Mac dependency
to the Windows port.
