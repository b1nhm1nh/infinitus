import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Settings › Team. Identity, join by code, publish and read. LAN nearby
/// is macOS/Linux-only (phase 02). Fetch on activate and on an explicit
/// button — nothing periodic.
public final class TeamPane: SettingsPane {
    public static let descriptor = SettingsCatalogWin.team

    private var ctx: PaneContext?

    private var identityKidHwnd: HWND?
    private var identityNameHwnd: HWND?
    private var gitStatusHwnd: HWND?
    private var lockStatusHwnd: HWND?
    private var errorHwnd: HWND?

    private var createNameHwnd: HWND?
    private var createLeaderHwnd: HWND?
    private var createRemoteHwnd: HWND?
    private var createTokenHwnd: HWND?
    private var createBtnHwnd: HWND?

    private var joinNameHwnd: HWND?
    private var joinCodeHwnd: HWND?
    private var joinBtnHwnd: HWND?

    private var teamComboHwnd: HWND?
    private var teamStatusHwnd: HWND?
    private var rosterHwnd: HWND?
    private var codeHwnd: HWND?
    private var fetchBtnHwnd: HWND?
    private var publishBtnHwnd: HWND?
    private var mintCodeBtnHwnd: HWND?

    private var lastPassHwnd: HWND?
    private var driversEmptyHwnd: HWND?
    private var revokeBtns: [HWND?] = []

    private var busy = false
    private var snapshot = Snapshot()
    private var computedHeight: Int32 = 900
    private var lastLayoutWidth: Int32 = 0
    private var lastLayoutHeight: Int32 = 0

    private enum Cmd {
        static let create: Int32 = 1
        static let join: Int32 = 2
        static let fetch: Int32 = 3
        static let publish: Int32 = 4
        static let mintCode: Int32 = 5
        static let teamCombo: Int32 = 6
        static let revokeBase: Int32 = 100
        static let revokeCount: Int32 = 16
    }

    private struct TeamRow: Sendable {
        var id: String
        var name: String
        var role: String
        var remote: String
        var kid: String
        var leaders: Int
        var members: Int
        var requests: Int
        var rosterLine: String
    }

    private struct GrantRow: Sendable {
        var id: String
        var line: String
    }

    private struct Snapshot: Sendable {
        var kid: String?
        var displayName: String = ""
        var gitFound: Bool = false
        var gitPath: String?
        var lockOn: Bool = false
        var teams: [TeamRow] = []
        var selectedID: String?
        var code: String?
        var error: String?
        var statusLine: String = ""
        var grants: [GrantRow] = []
        var lastPassLine: String = ""
    }

    /// Same shape as `TeamSupervisor.LastPass` — tray does not link InfinitusWin.
    private struct LastPassFile: Codable {
        var at: Int
        var answered: Int
        var lastOutcome: String?
        var lastRefusal: String?
        var error: String?
    }

    public init() {}

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        let base = ctx.idBase
        identityKidHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        identityNameHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        gitStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        lockStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        errorHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)

        createNameHwnd = PaneControls.edit(in: ctx, id: base + 20, x: 0, y: 0, w: 0, h: 0)
        createLeaderHwnd = PaneControls.edit(in: ctx, id: base + 21, x: 0, y: 0, w: 0, h: 0)
        createRemoteHwnd = PaneControls.edit(in: ctx, id: base + 22, x: 0, y: 0, w: 0, h: 0)
        createTokenHwnd = PaneControls.edit(in: ctx, id: base + 23, x: 0, y: 0, w: 0, h: 0, password: true)
        createBtnHwnd = PaneControls.button("Create team", in: ctx, id: base + Cmd.create, x: 0, y: 0, w: 0, h: 0)

        joinNameHwnd = PaneControls.edit(in: ctx, id: base + 24, x: 0, y: 0, w: 0, h: 0)
        joinCodeHwnd = PaneControls.edit(in: ctx, id: base + 25, x: 0, y: 0, w: 0, h: 0, multiline: true)
        joinBtnHwnd = PaneControls.button("Request to join", in: ctx, id: base + Cmd.join, x: 0, y: 0, w: 0, h: 0)

        teamComboHwnd = PaneControls.combo([], in: ctx, id: base + Cmd.teamCombo, x: 0, y: 0, w: 0, h: 0)
        teamStatusHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0)
        rosterHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        codeHwnd = PaneControls.edit(in: ctx, id: base + 26, x: 0, y: 0, w: 0, h: 0, multiline: true, readOnly: true)
        fetchBtnHwnd = PaneControls.button("Fetch now", in: ctx, id: base + Cmd.fetch, x: 0, y: 0, w: 0, h: 0)
        publishBtnHwnd = PaneControls.button("Publish now", in: ctx, id: base + Cmd.publish, x: 0, y: 0, w: 0, h: 0)
        mintCodeBtnHwnd = PaneControls.button("Make a code", in: ctx, id: base + Cmd.mintCode, x: 0, y: 0, w: 0, h: 0)

        lastPassHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        driversEmptyHwnd = PaneControls.label("", in: ctx, x: 0, y: 0, w: 0, h: 0, caption: true)
        revokeBtns = (0..<Cmd.revokeCount).map { i in
            PaneControls.button("Revoke", in: ctx, id: base + Cmd.revokeBase + i, x: 0, y: 0, w: 0, h: 0)
        }
        for btn in revokeBtns { if let h = btn { ShowWindow(h, SW_HIDE) } }

        let defaultName = ProcessInfo.processInfo.environment["USERNAME"] ?? "Windows"
        PaneControls.setText(createLeaderHwnd, defaultName)
        PaneControls.setText(joinNameHwnd, defaultName)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        lastLayoutWidth = width
        lastLayoutHeight = height
        ctx.recycleTransients()
        let m = ctx.metrics
        let pad = m.pad
        let fieldH = m.fieldHeight
        let btnH = m.buttonHeight
        let colW = m.labelColumn
        let fullW = max(100, width - pad * 2)
        let editW = max(80, fullW - colW)

        var y = pad
        y = PaneControls.sectionHeader("Identity", in: ctx, y: y, width: width)
        if let h = identityNameHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(4)
        if let h = identityKidHwnd { MoveWindow(h, pad, y, fullW, fieldH, true) }
        y += fieldH + m.px(4)
        if let h = gitStatusHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(20)
        if let h = lockStatusHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true) }
        y += m.px(22)
        if let h = errorHwnd { MoveWindow(h, pad, y, fullW, m.px(36), true) }
        y += m.px(40)

        y = PaneControls.sectionHeader("Create a team", in: ctx, y: y, width: width)
        _ = PaneControls.label("Team name:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = createNameHwnd { MoveWindow(h, pad + colW, y, editW, fieldH, true) }
        y += fieldH + m.px(6)
        _ = PaneControls.label("Your name:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = createLeaderHwnd { MoveWindow(h, pad + colW, y, editW, fieldH, true) }
        y += fieldH + m.px(6)
        _ = PaneControls.label("Empty repo URL:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = createRemoteHwnd { MoveWindow(h, pad + colW, y, editW, fieldH, true) }
        y += fieldH + m.px(6)
        _ = PaneControls.label("Write token:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = createTokenHwnd { MoveWindow(h, pad + colW, y, editW, fieldH, true) }
        y += fieldH + m.px(8)
        if let h = createBtnHwnd { MoveWindow(h, pad, y, m.px(130), btnH, true) }
        y += btnH + m.px(8)
        y += PaneControls.helpText(
            "Paste the URL of an empty private repo and a token that can push to it — or an ssh URL your agent can use. The token stays in %APPDATA%\\Infinitus\\teams\\secrets, never on argv.",
            in: ctx, x: pad, y: y, width: fullW) + m.px(12)

        y = PaneControls.sectionHeader("Join a team", in: ctx, y: y, width: width)
        _ = PaneControls.label("Your name:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = joinNameHwnd { MoveWindow(h, pad + colW, y, editW, fieldH, true) }
        y += fieldH + m.px(6)
        _ = PaneControls.label("Team code:", in: ctx, x: pad, y: y + m.px(2), w: colW, h: fieldH, transient: true)
        if let h = joinCodeHwnd { MoveWindow(h, pad + colW, y, editW, m.px(64), true) }
        y += m.px(70)
        if let h = joinBtnHwnd { MoveWindow(h, pad, y, m.px(150), btnH, true) }
        y += btnH + m.px(8)
        y += PaneControls.helpText(
            "LAN discovery is macOS/Linux-only. On Windows, join by code: a leader runs infinitusctl team code (or Make a code below) and you paste it here.",
            in: ctx, x: pad, y: y, width: fullW) + m.px(12)

        y = PaneControls.sectionHeader("This PC's teams", in: ctx, y: y, width: width)
        if let h = teamComboHwnd { MoveWindow(h, pad, y, m.px(280), m.px(140), true) }
        y += fieldH + m.px(8)
        if let h = teamStatusHwnd { MoveWindow(h, pad, y, fullW, m.px(36), true) }
        y += m.px(40)
        if let h = rosterHwnd { MoveWindow(h, pad, y, fullW, m.px(48), true) }
        y += m.px(52)
        if let f = fetchBtnHwnd, let p = publishBtnHwnd, let c = mintCodeBtnHwnd {
            MoveWindow(f, pad, y, m.px(110), btnH, true)
            MoveWindow(p, pad + m.px(120), y, m.px(120), btnH, true)
            MoveWindow(c, pad + m.px(250), y, m.px(130), btnH, true)
        }
        y += btnH + m.px(8)
        _ = PaneControls.label("Team code (leaders):", in: ctx, x: pad, y: y, w: fullW, h: m.px(16), caption: true, transient: true)
        y += m.px(18)
        if let h = codeHwnd { MoveWindow(h, pad, y, fullW, m.px(72), true) }
        y += m.px(80)
        y += PaneControls.helpText(
            "Fetch and Publish run off the UI thread and only when you ask — nothing ticks while this pane is open. Nearby LAN invites stay on macOS/Linux.",
            in: ctx, x: pad, y: y, width: fullW) + m.px(12)

        y = PaneControls.sectionHeader("Drivers", in: ctx, y: y, width: width)
        if let h = lastPassHwnd { MoveWindow(h, pad, y, fullW, m.px(36), true) }
        y += m.px(40)
        if snapshot.grants.isEmpty {
            if let h = driversEmptyHwnd { MoveWindow(h, pad, y, fullW, m.px(18), true); ShowWindow(h, SW_SHOW) }
            y += m.px(22)
            for btn in revokeBtns { if let h = btn { ShowWindow(h, SW_HIDE) } }
        } else {
            if let h = driversEmptyHwnd { ShowWindow(h, SW_HIDE) }
            let shown = min(snapshot.grants.count, Int(Cmd.revokeCount))
            for i in 0..<shown {
                _ = PaneControls.label(snapshot.grants[i].line, in: ctx, x: pad, y: y, w: max(80, fullW - m.px(90)), h: m.px(32), caption: true, transient: true)
                if let h = revokeBtns[i] {
                    ShowWindow(h, SW_SHOW)
                    MoveWindow(h, pad + fullW - m.px(80), y, m.px(80), btnH, true)
                }
                y += m.px(36)
            }
            for i in shown..<revokeBtns.count {
                if let h = revokeBtns[i] { ShowWindow(h, SW_HIDE) }
            }
        }
        y += PaneControls.helpText(
            "Revoke is local and takes effect on the next command — nothing is pushed to the driver, and work already in flight is not interrupted. Owned sessions (this daemon's stdin) and sessions with a live pipe are drivable; a granted key on any other session answers noSurface.",
            in: ctx, x: pad, y: y, width: fullW) + pad

        computedHeight = y
        PaneHost.setContentHeight(ctx.host, y)
    }

    public func contentHeight(width: Int32) -> Int32 { computedHeight }

    public func activate() { reload(fetch: true) }
    public func deactivate() {}

    public func command(id: Int32, code: UINT, from: HWND?) -> Bool {
        guard let ctx else { return false }
        let rel = id - ctx.idBase
        switch rel {
        case Cmd.create:
            createTeam()
            return true
        case Cmd.join:
            joinTeam()
            return true
        case Cmd.fetch:
            runOnTeam { client, _ in
                _ = try client.fetch()
                return "Fetched."
            }
            return true
        case Cmd.publish:
            publishNow()
            return true
        case Cmd.mintCode:
            runOnTeam { client, _ in
                guard client.isLeader else { throw TeamClient.ClientError.notALeader }
                _ = try client.fetch()
                return try client.code()
            }
            return true
        case Cmd.teamCombo:
            if code == UINT(CBN_SELCHANGE) {
                snapshot.selectedID = selectedTeamID()
                reload(fetch: false)
            }
            return true
        case Cmd.revokeBase..<(Cmd.revokeBase + Cmd.revokeCount):
            let index = Int(rel - Cmd.revokeBase)
            if snapshot.grants.indices.contains(index) {
                revokeGrant(id: snapshot.grants[index].id)
            }
            return true
        default:
            return false
        }
    }

    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { WinDark.drawButton(item) }

    private func selectedTeamID() -> String? {
        let sel = PaneControls.comboSelection(teamComboHwnd)
        return snapshot.teams.first { comboLabel($0) == sel }?.id ?? snapshot.teams.first?.id
    }

    private func comboLabel(_ row: TeamRow) -> String { "\(row.name) (\(row.role))" }

    private func paint() {
        let kid = snapshot.kid ?? "(none yet — created on first join or create)"
        PaneControls.setText(identityKidHwnd, "kid  \(kid)")
        PaneControls.setText(identityNameHwnd, "name  \(snapshot.displayName)")
        if snapshot.gitFound {
            PaneControls.setText(gitStatusHwnd, snapshot.gitPath.map { "git  \($0)" } ?? "git  found")
        } else {
            PaneControls.setText(gitStatusHwnd, "git not found — install Git for Windows")
        }
        if snapshot.lockOn {
            PaneControls.setText(lockStatusHwnd, "Lock is on.")
        } else {
            PaneControls.setText(lockStatusHwnd, TeamGate.reason + " (Lock pane).")
        }
        PaneControls.setText(errorHwnd, snapshot.error ?? snapshot.statusLine)

        let gateOpen = snapshot.lockOn && snapshot.gitFound && !busy
        PaneControls.enable(createBtnHwnd, gateOpen)
        PaneControls.enable(joinBtnHwnd, gateOpen)
        let inTeam = snapshot.selectedID != nil || !snapshot.teams.isEmpty
        PaneControls.enable(fetchBtnHwnd, inTeam && snapshot.gitFound && !busy)
        PaneControls.enable(publishBtnHwnd, inTeam && snapshot.gitFound && !busy)
        let selected = snapshot.teams.first { $0.id == snapshot.selectedID } ?? snapshot.teams.first
        PaneControls.enable(mintCodeBtnHwnd, selected?.role == "leader" && snapshot.gitFound && !busy)

        if let selected {
            PaneControls.setText(teamStatusHwnd,
                                 "\(selected.name) · \(selected.role) · \(selected.leaders) leaders · \(selected.members) members · \(selected.requests) requests")
            PaneControls.setText(rosterHwnd, selected.rosterLine + "\nstore  " + selected.remote)
        } else {
            PaneControls.setText(teamStatusHwnd, "Not in a team yet.")
            PaneControls.setText(rosterHwnd, "")
        }
        if let code = snapshot.code { PaneControls.setText(codeHwnd, code) }
        PaneControls.setText(lastPassHwnd, snapshot.lastPassLine)
        PaneControls.setText(driversEmptyHwnd,
                             snapshot.grants.isEmpty ? "Nobody can drive your sessions." : "")
        let shown = min(snapshot.grants.count, Int(Cmd.revokeCount))
        for i in 0..<shown { PaneControls.enable(revokeBtns[i], !busy) }
    }

    private func refillCombo() {
        guard let hwnd = teamComboHwnd else { return }
        SendMessageW(hwnd, UINT(CB_RESETCONTENT), 0, 0)
        for row in snapshot.teams {
            let wide = Array(comboLabel(row).utf16) + [0]
            wide.withUnsafeBufferPointer { buf in
                SendMessageW(hwnd, UINT(CB_ADDSTRING), 0, LPARAM(UInt(bitPattern: buf.baseAddress)))
            }
        }
        if let selected = snapshot.teams.first(where: { $0.id == snapshot.selectedID }) ?? snapshot.teams.first {
            PaneControls.setComboSelection(hwnd, comboLabel(selected))
        }
    }

    private func reload(fetch: Bool) {
        guard let ctx, !busy else { return }
        busy = true
        snapshot.statusLine = fetch ? "Loading…" : snapshot.statusLine
        paint()
        let keepID = snapshot.selectedID
        ctx.async({
            Self.loadSnapshot(selectedID: keepID, fetch: fetch)
        }, then: { [weak self] snap in
            guard let self else { return }
            self.busy = false
            self.applySnapshot(snap)
        })
    }

    private func applySnapshot(_ snap: Snapshot) {
        snapshot = snap
        refillCombo()
        if lastLayoutWidth > 0 {
            layout(width: lastLayoutWidth, height: lastLayoutHeight)
        }
        paint()
    }

    private static func loadSnapshot(selectedID: String?, fetch: Bool) -> Snapshot {
        var snap = Snapshot()
        snap.displayName = ProcessInfo.processInfo.environment["USERNAME"] ?? "Windows"
        snap.gitPath = GitLocator.locate()
        snap.gitFound = snap.gitPath != nil
        snap.lockOn = TeamGate.check(lockEnabled: WinLockStore.load().enabled) == .allowed
        let paths = TeamPaths.standard()
        let secrets = FileSecrets(dir: paths.secretsDir)
        snap.kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
        guard snap.gitFound else {
            snap.error = "\(TeamGit.GitError.gitNotFound)"
            snap.selectedID = selectedID ?? paths.teamIDs().first
            fillDrivers(&snap, paths: paths)
            return snap
        }
        for id in paths.teamIDs() {
            do {
                let client = try TeamClient.open(id: id, paths: paths, secrets: secrets)
                if fetch { _ = try? client.fetch() }
                let status = try client.status()
                let roster = client.roster?.doc
                let names = (roster?.leaders.map { "\($0.name) (leader)" } ?? [])
                    + (roster?.members.map(\.name) ?? [])
                snap.teams.append(TeamRow(
                    id: status.id, name: status.name, role: status.role, remote: status.remote,
                    kid: status.kid, leaders: status.leaders, members: status.members,
                    requests: status.requests,
                    rosterLine: names.isEmpty ? "No roster yet." : names.joined(separator: " · ")))
            } catch {
                snap.error = TeamGit.masked("\(error)")
            }
        }
        snap.selectedID = selectedID.flatMap { id in snap.teams.contains(where: { $0.id == id }) ? id : nil }
            ?? snap.teams.first?.id
        fillDrivers(&snap, paths: paths)
        return snap
    }

    private static func fillDrivers(_ snap: inout Snapshot, paths: TeamPaths) {
        guard let id = snap.selectedID else {
            snap.grants = []
            snap.lastPassLine = ""
            return
        }
        let teamDir = paths.teamDir(id)
        let roster = (try? Data(contentsOf: paths.rosterFile(id)))
            .flatMap { try? CanonicalJSON.decode(Signed<TeamRoster>.self, from: $0) }?.doc
        snap.grants = TeamGrants.load(teamDir: teamDir).grants.map {
            GrantRow(id: $0.id, line: grantLine($0, roster: roster))
        }
        snap.lastPassLine = lastPassCaption(teamDir: teamDir)
    }

    private static func grantLine(_ grant: TeamGrants.Grant, roster: TeamRoster?) -> String {
        let who: String
        switch grant.audience {
        case .off: who = "nobody"
        case .leaders: who = "leaders"
        case .team: who = "whole team"
        case .members(let kids):
            who = kids.map { kid in
                roster?.everyone.first { $0.keys.kid == kid }?.name ?? String(kid.prefix(8))
            }.joined(separator: ", ")
        }
        let sessions: String
        switch grant.sessions {
        case .all: sessions = "all sessions"
        case .some(let ids): sessions = ids.count == 1 ? "1 session" : "\(ids.count) sessions"
        }
        let caps = grant.capabilities.sorted().joined(separator: ", ")
        return "\(who) · \(sessions) · \(caps) · since \(stamp(grant.since))"
    }

    private static func lastPassCaption(teamDir: URL) -> String {
        let file = teamDir.appendingPathComponent("control-last-pass.json")
        guard let data = try? Data(contentsOf: file),
              let pass = try? JSONDecoder().decode(LastPassFile.self, from: data) else {
            return "No grantor pass yet. Run infinitus-win serve --team-grant."
        }
        if let error = pass.error, !error.isEmpty {
            return "Last pass \(stamp(pass.at)): \(error)"
        }
        var line = "Last pass \(stamp(pass.at)): answered \(pass.answered)"
        if let outcome = pass.lastOutcome { line += " · last \(outcome)" }
        if let refusal = pass.lastRefusal { line += " · refused \(refusal)" }
        return line
    }

    private static func stamp(_ at: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    private func createTeam() {
        guard let ctx, !busy else { return }
        let name = PaneControls.text(createNameHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let leader = PaneControls.text(createLeaderHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = PaneControls.text(createRemoteHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenRaw = PaneControls.text(createTokenHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !leader.isEmpty, !remote.isEmpty else {
            snapshot.error = "Team name, your name and an empty repo URL are required."
            paint()
            return
        }
        busy = true
        snapshot.statusLine = "Creating team…"
        snapshot.error = nil
        paint()
        ctx.async({
            let paths = TeamPaths.standard()
            let secrets = FileSecrets(dir: paths.secretsDir)
            let token = tokenRaw.isEmpty ? nil : tokenRaw
            _ = try TeamClient.create(name: name, remote: remote, token: token, leaderName: leader,
                                      paths: paths, secrets: secrets)
            return Self.loadSnapshot(selectedID: nil, fetch: false)
        }, then: { [weak self] (result: Result<Snapshot, Error>) in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snap):
                var snap = snap
                snap.statusLine = "Created."
                self.applySnapshot(snap)
                PaneControls.setText(self.createTokenHwnd, "")
            case .failure(let error):
                self.snapshot.error = TeamGit.masked("\(error)")
                self.paint()
            }
        })
    }

    private func joinTeam() {
        guard let ctx, !busy else { return }
        let name = PaneControls.text(joinNameHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        let code = PaneControls.text(joinCodeHwnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !code.isEmpty else {
            snapshot.error = "Your name and a team code are required."
            paint()
            return
        }
        busy = true
        snapshot.statusLine = "Requesting to join…"
        snapshot.error = nil
        paint()
        let device = ProcessInfo.processInfo.environment["COMPUTERNAME"] ?? "Windows"
        ctx.async({
            let paths = TeamPaths.standard()
            let secrets = FileSecrets(dir: paths.secretsDir)
            _ = try TeamClient.request(code: code, name: name, devices: [device], platform: "windows",
                                       paths: paths, secrets: secrets)
            return Self.loadSnapshot(selectedID: nil, fetch: true)
        }, then: { [weak self] (result: Result<Snapshot, Error>) in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snap):
                var snap = snap
                snap.statusLine = "Requested. Waiting for a leader to approve."
                self.applySnapshot(snap)
            case .failure(let error):
                self.snapshot.error = TeamGit.masked("\(error)")
                self.paint()
            }
        })
    }

    private func publishNow() {
        runOnTeam { client, paths in
            _ = try client.fetch()
            let claudeDir = ClaudeSessions.configHome()
            var sources = TeamPublisher.Sources(
                projectsDir: claudeDir.appendingPathComponent("projects"),
                home: NSHomeDirectory())
            sources.codexDir = StatsScanner.defaultCodexDir()
            sources.cacheURL = paths.teamDir(client.config.id).appendingPathComponent("scan-cache.json")
            sources.liveSessions = ClaudeSessions.list(claudeDir: claudeDir)
            sources.crashes = CrashStore(directory: CrashStore.defaultDirectory()).list()
            let report = try TeamPublisher(client: client, paths: paths).publish(sources: sources)
            return "Published \(report.published.count) files."
        }
    }

    private func runOnTeam(_ work: @escaping @Sendable (TeamClient, TeamPaths) throws -> String) {
        guard let ctx, !busy else { return }
        let id = selectedTeamID()
        guard let id else {
            snapshot.error = "not in a team"
            paint()
            return
        }
        busy = true
        snapshot.statusLine = "Working…"
        snapshot.error = nil
        paint()
        ctx.async({
            let paths = TeamPaths.standard()
            let secrets = FileSecrets(dir: paths.secretsDir)
            let client = try TeamClient.open(id: id, paths: paths, secrets: secrets)
            let line = try work(client, paths)
            var snap = Self.loadSnapshot(selectedID: id, fetch: false)
            snap.statusLine = line
            if line.contains("infinitus") || line.count > 40 { snap.code = line }
            return snap
        }, then: { [weak self] (result: Result<Snapshot, Error>) in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snap):
                self.applySnapshot(snap)
            case .failure(let error):
                self.snapshot.error = TeamGit.masked("\(error)")
                self.paint()
            }
        })
    }

    private func revokeGrant(id: String) {
        guard let ctx, !busy else { return }
        guard let teamID = selectedTeamID() else {
            snapshot.error = "not in a team"
            paint()
            return
        }
        busy = true
        snapshot.statusLine = "Revoking…"
        snapshot.error = nil
        paint()
        ctx.async({
            let paths = TeamPaths.standard()
            let teamDir = paths.teamDir(teamID)
            var grants = TeamGrants.load(teamDir: teamDir)
            _ = grants.remove(id: id)
            try grants.save(teamDir: teamDir)
            var snap = Self.loadSnapshot(selectedID: teamID, fetch: false)
            snap.statusLine = "Revoked. Takes effect on the next command."
            return snap
        }, then: { [weak self] (result: Result<Snapshot, Error>) in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snap):
                self.applySnapshot(snap)
            case .failure(let error):
                self.snapshot.error = TeamGit.masked("\(error)")
                self.paint()
            }
        })
    }
}

private extension PaneContext {
    /// Same as `async(_:then:)` but catches thrown errors so a git miss
    /// paints on the pane instead of dying on the worker.
    func async<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T,
        then apply: @escaping (Result<T, Error>) -> Void
    ) {
        async({
            Result { try work() }
        }, then: apply)
    }
}
