import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: the phone companion and its routes, plus settings sync across
/// Macs (iCloud, file). Was "Sync" — it lived in Display before, which is
/// the wrong home (user report 2026-08-30): it syncs notify flags and
/// engine config too, not just display prefs.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The LAN server publishes its own state (port, failures), so the
    /// pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var server: MirrorServer
    /// The quick tunnel publishes its URL the same way — the QR list
    /// grows a third entry the moment cloudflared names the hostname.
    @ObservedObject private var tunnel: QuickTunnel
    /// The token is masked until asked for: settings panes get shared in
    /// screenshots, and this one is a read key.
    @State private var revealToken = false
    /// Tailscale coming up (or going away) changes nothing the models
    /// publish — the utun address just appears. Re-probe while the pane
    /// is up so the status row and the route list follow it.
    @State private var tailscale = TailscaleStatus.notInstalled
    /// Open until every step is ticked; closes itself once paired.
    @State private var walkthroughOpen = true
    private let reprobe = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _server = ObservedObject(wrappedValue: app.mirrorServer)
        _tunnel = ObservedObject(wrappedValue: app.quickTunnel)
    }

    var body: some View {
        Form {
            // The phone companion's transport (#9): this Mac serves its
            // last fleet snapshot to InfinitusMobile — on the LAN, over a
            // tailnet, or through a throwaway Cloudflare tunnel. No
            // backend of ours anywhere; the pairing token is the lock.
            walkthrough
            Section("Phone companion") {
                Toggle("Serve the fleet to my phone",
                       isOn: $app.mirrorLANEnabled)
                    .help("Advertises this Mac as _infinitus._tcp and answers "
                          + "GET /snapshot with the same fleet snapshot the "
                          + "menu bar shows. Every request must carry the "
                          + "pairing token below.")
                if let status = server.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Pairing token") {
                    HStack(spacing: 8) {
                        Text(revealToken ? app.mirrorPairToken
                             : MirrorPairing.mask(app.mirrorPairToken))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(revealToken ? "Hide" : "Reveal") {
                            revealToken.toggle()
                        }
                        Button("Copy") { copy(app.mirrorPairToken) }
                        Button("Regenerate") {
                            app.regeneratePairToken()
                        }
                        .help("Every paired phone must scan again.")
                    }
                }
                Text("Requests without `Authorization: Bearer <token>` (or "
                     + "`?t=<token>`) get a 401. The snapshot carries account "
                     + "aliases, emails and usage estimates; never tokens or "
                     + "push secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if app.mirrorLANEnabled {
                Section("Pair a phone") {
                    if app.pairRoutes.isEmpty {
                        Text("Waiting for the listener to come up…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            if let image = PairQR.image(for: app.pairURL) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 110, height: 110)
                                    .padding(4)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(app.pairRoutes) { route in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(route.title).font(.callout).bold()
                                        HStack {
                                            Text(route.endpoint)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                            Button("Copy") { copy(route.endpoint) }
                                        }
                                    }
                                }
                                Button("Copy pair link") { copy(app.pairURL) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        Text("One scan pairs every route. The phone tries them in "
                             + "this order and keeps whichever answers — a tunnel "
                             + "URL that changes on restart just falls through to "
                             + "Wi-Fi or Tailscale.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Anywhere") {
                    tailscaleRow
                    if QuickTunnel.binaryPath != nil {
                        Toggle("Expose through a Cloudflare quick tunnel",
                               isOn: $app.mirrorTunnelEnabled)
                            .help("Runs `cloudflared tunnel --url` and puts the "
                                  + "random https URL on a QR. No Cloudflare "
                                  + "account, no backend — and no secrecy in "
                                  + "the URL itself.")
                        if let status = tunnel.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("The URL is public and changes every start; the "
                             + "pairing token is the only thing keeping the "
                             + "snapshot private. Stops when you turn this off "
                             + "or quit.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Cloudflare quick tunnel") {
                            Button("Copy install command") { copy("brew install cloudflared") }
                        }
                        Text("Not installed. `brew install cloudflared` adds it; "
                             + "a toggle appears here to expose this Mac through "
                             + "a random trycloudflare.com URL, no account needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onAppear { probeTailscale() }
                .onReceive(reprobe) { _ in probeTailscale() }
            }
            Section("iCloud") {
                Toggle("Sync settings via iCloud Drive", isOn: $sync.enabled)
                    .help("Display prefs, custom themes, and set cswap "
                          + "engine settings travel through one JSON file "
                          + "in iCloud Drive/Infinitus. Never credentials "
                          + "or push secrets. Last writer wins.")
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Manual path for machines outside the iCloud account
            // (user request 2026-08-30). Same snapshot, same scope.
            Section("File") {
                LabeledContent("Settings as a file") {
                    HStack {
                        Button("Export…") { runExportPanel() }
                        Button("Import…") { runImportPanel() }
                    }
                }
                Text("The same settings the iCloud sync carries — display "
                     + "prefs, custom themes, cswap engine config. Never "
                     + "credentials or push secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Walkthrough

    /// One step of "Set up your phone": live state, not a static how-to.
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let done: Bool
    }

    private var steps: [Step] {
        let serving = app.mirrorLANEnabled && server.port != nil
        let routes = app.pairRoutes
        let remote = routes.contains { $0.id != "lan" }
        return [
            Step(id: 1, title: "Serve the fleet to my phone",
                 detail: "The toggle below. This Mac answers with its fleet "
                       + "snapshot; nothing leaves the machine otherwise.",
                 done: serving),
            Step(id: 2, title: "Put Infinitus on the phone",
                 detail: "The iOS companion is in the repo under ios/ (build "
                       + "it in Xcode until it reaches TestFlight).",
                 done: server.lastServed != nil),
            Step(id: 3, title: "Pick how the phone reaches this Mac",
                 detail: remote
                    ? "Same Wi-Fi works already; a remote route is up too."
                    : "Same Wi-Fi needs nothing. From anywhere: Tailscale "
                      + "on both devices (see Anywhere), or a Cloudflare "
                      + "quick tunnel.",
                 done: !routes.isEmpty),
            Step(id: 4, title: "Scan the QR from the phone",
                 detail: "On the phone: Settings → Mac connection → Scan QR, "
                       + "pointing at Pair a phone below — one QR carries "
                       + "every route.",
                 done: server.lastServed != nil),
        ]
    }

    private var walkthrough: some View {
        let steps = self.steps
        let doneCount = steps.filter(\.done).count
        return Section {
            DisclosureGroup(isExpanded: $walkthroughOpen) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "\(step.id).circle")
                            .foregroundStyle(step.done ? .green : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).strikethrough(step.done, color: .secondary)
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                if let when = server.lastServed {
                    Text("Phone last fetched the fleet \(when.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Hand the rest to an agent (user 2026-09-02): the same
                // state as the checklist, plus the exact commands, as one
                // pasteable brief. The token rides along only while it's
                // revealed above — a masked pane copies a masked brief.
                HStack {
                    Button("Copy for an AI agent") { copy(agentBrief(steps)) }
                    Text(revealToken
                         ? "Includes the pairing token."
                         : "Token left out — Reveal it below to include it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                LabeledContent("Set up your phone") {
                    Text(doneCount == steps.count ? "all set" : "\(doneCount) of \(steps.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { walkthroughOpen = doneCount < steps.count }
    }

    /// Markdown a coding agent can act on: what's done, what's left, and
    /// the commands for each remaining step. Everything here is derived
    /// from the live state so it never disagrees with the checklist.
    private func agentBrief(_ steps: [Step]) -> String {
        let routes = app.pairRoutes
        let token = revealToken ? app.mirrorPairToken
            : "<hidden — in Infinitus: Settings → Devices → Pairing token → Reveal/Copy>"
        let port = server.port.map(String.init) ?? "?"
        var out = ["# Infinitus — set up the phone companion (agent brief)",
                   "Generated by Infinitus on \(Host.current().localizedName ?? "this Mac") "
                   + "at \(Date().formatted(date: .abbreviated, time: .shortened)). "
                   + "Source: https://github.com/deathemperor/infinitus", "",
                   "## State"]
        for step in steps { out.append("- [\(step.done ? "x" : " ")] \(step.id). \(step.title)") }
        out.append("- Listener: \(app.mirrorLANEnabled ? "on, port \(port)" : "off")")
        for r in routes { out.append("- Route \"\(r.title)\": \(r.endpoint)") }
        out.append("- Pairing token: \(token)")
        out.append("- Tailscale on this Mac: \(tailscaleLine)")
        out.append("- cloudflared on this Mac: \(QuickTunnel.binaryPath ?? "not installed")")
        out += ["", "## Do the unticked steps, in order",
                "1. Serving: a toggle in the Infinitus menu bar app (Settings → Devices → "
                + "\"Serve the fleet to my phone\"). No shell equivalent — ask the user to flip it.",
                "2. Phone app: the iOS companion lives in ios/ of the repo. From a clone:",
                "   cd ios && xcodegen generate",
                "   xcrun devicectl list devices            # find the phone's UDID",
                "   xcodebuild -project InfinitusMobile.xcodeproj -scheme InfinitusMobile "
                + "-configuration Debug -destination 'id=<UDID>' -derivedDataPath build "
                + "-allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Automatic build",
                "   xcrun devicectl device install app --device <UDID> "
                + "build/Build/Products/Debug-iphoneos/InfinitusMobile.app",
                "   (a free personal team works; the user trusts the profile once on the phone)",
                "3. A route. Same Wi-Fi needs nothing. From anywhere, either:",
                "   - Tailscale: `brew install --cask tailscale-app` (the pkg asks for an admin "
                + "password — the user types it), open Tailscale, sign in; on the phone install "
                + "Tailscale from the App Store and sign into the same tailnet. Infinitus shows "
                + "the tailnet route by itself.",
                "   - Cloudflare quick tunnel: `brew install cloudflared`, then in Infinitus "
                + "Settings → Devices → Anywhere turn on the tunnel (random public URL; the token "
                + "is the only lock).",
                "4. Pair: on the phone, Settings → Mac connection → Scan QR, pointing at "
                + "Infinitus Settings → Devices → Pair a phone (one QR carries every route). "
                + "Or enter a route address and the pairing token by hand in the same screen.",
                "", "## Verify",
                "curl -s -o /dev/null -w '%{http_code}\\n' -H 'Authorization: Bearer <token>' "
                + "http://<host>:\(port)/snapshot   # 200 = paired route works; 401 = wrong token",
                "Infinitus ticks step 4 the moment the phone fetches with the right token."]
        return out.joined(separator: "\n")
    }

    private var tailscaleLine: String {
        switch tailscale {
        case .notInstalled: return "not installed"
        case .installed: return "installed, not connected"
        case .connected(let ip): return "connected, \(ip)"
        }
    }

    private func probeTailscale() {
        let now = TailscaleStatus.probe(addresses: LocalAddresses.ipv4())
        if now != tailscale { tailscale = now }
    }

    /// Guide, don't install: see TailscaleStatus.
    @ViewBuilder
    private var tailscaleRow: some View {
        switch tailscale {
        case .notInstalled:
            LabeledContent("Tailscale") {
                Button("Get Tailscale…") { NSWorkspace.shared.open(TailscaleStatus.downloadURL) }
            }
            Text("Free for personal use. Install it here and on the phone, "
                 + "sign both into the same tailnet, and a Tailscale route "
                 + "appears under Pair a phone by itself — reachable from "
                 + "anywhere, no port forwarding, no public URL.")
                .font(.caption).foregroundStyle(.secondary)
        case .installed(let app):
            LabeledContent("Tailscale") {
                if app.pathExtension == "app" {
                    Button("Open Tailscale") {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                } else {
                    Text("installed, not connected").font(.caption)
                }
            }
            Text("Installed but not connected — open it and sign in; the "
                 + "route shows up under Pair a phone once it is.")
                .font(.caption).foregroundStyle(.secondary)
        case .connected(let ip):
            LabeledContent("Tailscale") {
                Text("connected · \(ip)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("The Tailscale route is under Pair a phone. The phone needs "
                 + "Tailscale too, signed into the same tailnet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "infinitus-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.export(to: url) }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.importConfig(from: url) }
    }
}
