import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// iCloud settings sync, in its own pane — it lived in Display, which is
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

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _server = ObservedObject(wrappedValue: app.mirrorServer)
        _tunnel = ObservedObject(wrappedValue: app.quickTunnel)
    }

    var body: some View {
        Form {
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
            // The phone companion's transport (#9): this Mac serves its
            // last fleet snapshot to InfinitusMobile — on the LAN, over a
            // tailnet, or through a throwaway Cloudflare tunnel. No
            // backend of ours anywhere; the pairing token is the lock.
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
                    }
                    ForEach(app.pairRoutes) { route in
                        pairRow(route)
                    }
                }
                Section("Anywhere") {
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
                        Text("Install cloudflared (`brew install cloudflared`) "
                             + "to expose this Mac through a random "
                             + "trycloudflare.com URL without any account. "
                             + "Tailscale works too — with it running, the "
                             + "tailnet address shows up above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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

    /// One way in: its QR, its address, and what it costs to use.
    @ViewBuilder
    private func pairRow(_ route: PairRoute) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let image = PairQR.image(for: route.pairURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 110, height: 110)
                    .padding(4)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(route.title).font(.callout).bold()
                Text(route.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(route.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy address") { copy(route.endpoint) }
                    Button("Copy pair link") { copy(route.pairURL) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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
