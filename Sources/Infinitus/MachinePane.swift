import SwiftUI
import InfinitusCore
import InfinitusUI

/// Settings › Machine (#115): what many concurrent Claude sessions do
/// to this Mac, and the confirmed actions to fix it. Reads
/// `model.report`, refreshed on `AppModel`'s own refresh loop
/// (`MachineModel.tick()`) — nothing here polls on its own.
struct MachinePane: View {
    @ObservedObject var model: MachineModel

    @State private var pendingDisable: HookGroup?
    @State private var pendingKill: Runaways.Runaway?
    @State private var pendingReclaim = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            header
            if let report = model.report {
                summarySection(report)
                warningsSection(report)
                hooksSection(report)
                runawaysSection(report)
                residueSection(report)
            }
            sessionsSection(model.report)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Move \(pendingDisable?.owner ?? "")'s \(pendingDisable?.registrationCount ?? 0) hook registrations out of ~/.claude/settings.json? A backup is written beside it.",
            isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
            presenting: pendingDisable
        ) { group in
            Button("Disable", role: .destructive) {
                let owner = group.owner
                Task { resultMessage = await model.disableHook(owner: owner) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Send SIGTERM to the process group of \(pendingKill?.pid ?? 0), then SIGKILL after 3 s?",
            isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { runaway in
            Button("Kill", role: .destructive) {
                let pid = runaway.pid
                Task { resultMessage = await model.killRunaway(pid: pid) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(reclaimMessage, isPresented: $pendingReclaim) {
            Button("Reclaim", role: .destructive) { Task { resultMessage = await model.reclaim() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: header

    private var header: some View {
        Section {
            Toggle("Watch this Mac", isOn: $model.enabled)
            Text("one process listing a minute; the temp directory every five")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Sample now") { Task { resultMessage = nil; await model.sample() } }
                    .disabled(model.sampling)
                if model.sampling { ProgressView().controlSize(.small) }
                Spacer()
                if let at = model.lastSampledAt {
                    Text("sampled \(at.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let resultMessage {
                Text(resultMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: summary

    private func summarySection(_ report: MachineReport) -> some View {
        let s = report.sample
        return Section("Summary") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Load").foregroundStyle(.secondary)
                    Text("\(s.load1, specifier: "%.2f") / \(s.cores) cores")
                        .foregroundStyle(s.load1 > Double(s.cores) ? .red : .primary)
                }
                GridRow {
                    Text("Swap").foregroundStyle(.secondary)
                    Text("\(s.swapUsedMB) / \(s.swapTotalMB) MB")
                        .foregroundStyle(s.swapPct >= 90 ? .red : .primary)
                }
                GridRow {
                    Text("Processes").foregroundStyle(.secondary)
                    Text("\(s.processes) total, \(s.running) running, \(s.uninterruptible) uninterruptible, \(s.zombies) zombies")
                        .foregroundStyle(s.uninterruptible >= 50 ? .red : .primary)
                }
                GridRow {
                    Text("WindowServer").foregroundStyle(.secondary)
                    Text("\(s.windowServerCPU, specifier: "%.0f")% CPU")
                }
                GridRow {
                    Text("Temp entries").foregroundStyle(.secondary)
                    if let n = s.tempEntries {
                        Text("\(n)")
                    } else {
                        Text("listing timed out").foregroundStyle(.red)
                    }
                }
                GridRow {
                    Text("Claude sessions").foregroundStyle(.secondary)
                    Text("\(s.claudeRSSMB) MB resident")
                }
            }
            .font(PopupFont.caption).monospacedDigit()
        }
    }

    // MARK: warnings

    private func warningsSection(_ report: MachineReport) -> some View {
        Section("Warnings") {
            if report.warnings.isEmpty {
                Text("nothing to flag").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).foregroundStyle(.orange).font(PopupFont.caption)
                }
            }
        }
    }

    // MARK: hooks

    struct HookGroup: Identifiable {
        let owner: String
        let kind: HookRegistration.OwnerKind
        let events: [String]
        let spawnsPerHour: Double
        let heavy: Bool
        let instances: Int
        let helpers: Int
        let oldestSeconds: Int
        let stuckCount: Int
        let registrationCount: Int
        var id: String { owner }
    }

    private func hookGroups(_ report: MachineReport) -> [HookGroup] {
        Dictionary(grouping: report.hooks, by: \.registration.owner).map { owner, hooks in
            HookGroup(owner: owner,
                      kind: hooks.first!.registration.ownerKind,
                      events: Array(Set(hooks.map(\.registration.event))).sorted(),
                      spawnsPerHour: hooks.map(\.spawnsPerHour).reduce(0, +),
                      heavy: hooks.contains { $0.registration.heavy },
                      instances: hooks.map(\.live.instances).reduce(0, +),
                      helpers: hooks.map(\.live.helpers).reduce(0, +),
                      oldestSeconds: hooks.map(\.live.oldestSeconds).max() ?? 0,
                      stuckCount: hooks.filter(\.stuck).count,
                      registrationCount: hooks.count)
        }.sorted { $0.owner < $1.owner }
    }

    private func kindLabel(_ kind: HookRegistration.OwnerKind) -> String {
        switch kind {
        case .brew: return "brew"
        case .vendored: return "vendored"
        case .handInstalled: return "hand-installed"
        case .plugin: return "plugin"
        case .unknown: return "unknown"
        }
    }

    private func hooksSection(_ report: MachineReport) -> some View {
        Section("Hooks") {
            let groups = hookGroups(report)
            if groups.isEmpty {
                Text("no hook registrations").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(groups) { group in hookRow(group) }
            }
        }
    }

    @ViewBuilder
    private func hookRow(_ group: HookGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.owner).bold()
                Text("(\(kindLabel(group.kind)))").foregroundStyle(.secondary)
                if group.heavy {
                    Text("heavy").font(.caption2).padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                if group.kind == .plugin {
                    Text("managed by Claude Code").font(.caption2).foregroundStyle(.secondary)
                } else if model.parkedOwners.contains(group.owner) {
                    Button("Restore") {
                        let owner = group.owner
                        Task { resultMessage = await model.restoreHook(owner: owner) }
                    }
                } else {
                    Button("Disable…") { pendingDisable = group }
                }
            }
            Text(group.events.joined(separator: ", ") + " · \(Int(group.spawnsPerHour))/h expected")
                .font(PopupFont.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(group.instances) live" + (group.helpers > 0 ? " + \(group.helpers) helpers" : ""))
                Text("oldest \(group.oldestSeconds / 60) min")
                if group.stuckCount > 0 { Text("\(group.stuckCount) stuck").foregroundStyle(.red) }
            }
            .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: runaways

    private func runawaysSection(_ report: MachineReport) -> some View {
        Section("Runaways") {
            if report.runaways.isEmpty {
                Text("nothing flagged").foregroundStyle(.secondary).font(PopupFont.caption)
            } else {
                ForEach(report.runaways) { runaway in runawayRow(runaway, sessions: report.sessions) }
            }
        }
    }

    private func runawayRow(_ runaway: Runaways.Runaway, sessions: [SessionHealth]) -> some View {
        let sessionName = runaway.sessionPid.flatMap { pid in sessions.first { $0.pid == pid }?.name }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(runaway.rule).bold()
                Text(runaway.why).foregroundStyle(.secondary)
                Spacer()
                Button("Kill…") { pendingKill = runaway }
            }
            .font(PopupFont.caption)
            HStack(spacing: 8) {
                Text("\(runaway.rssMB) MB")
                Text("\(runaway.elapsedSeconds / 60) min")
                if let sessionName { Text(sessionName) }
            }
            .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(runaway.command)
                .font(PopupFont.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).help(runaway.command)
        }
        .padding(.vertical, 2)
    }

    // MARK: residue

    private var reclaimMessage: String {
        let residue = model.report?.residue
        return "\(residue?.staleSockets ?? 0) stale sockets, \(residue?.staleSessionEnvs ?? 0) session-env dirs, and temp files older than an hour that no process holds open"
    }

    private func residueSection(_ report: MachineReport) -> some View {
        let r = report.residue
        return Section("Residue") {
            Text("\(r.staleSockets) stale sockets, \(r.staleSessionEnvs) stale session-env dirs, \(r.tempEntries.map { "\($0)" } ?? "?") temp entries")
                .font(PopupFont.caption).monospacedDigit()
            Text("transcripts \(bytesString(r.transcriptsBytes)) · plugin cache \(bytesString(r.pluginCacheBytes)) · claude-mem \(bytesString(r.memBytes))")
                .font(PopupFont.caption).foregroundStyle(.secondary).monospacedDigit()
            Button("Reclaim…") { pendingReclaim = true }
        }
    }

    private func bytesString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: sessions

    private func sessionsSection(_ report: MachineReport?) -> some View {
        Section("Sessions") {
            Stepper("Notify when a session is idle for \(Int(model.idleHours)) h",
                    value: $model.idleHours, in: 1...72)
            if let sessions = report?.sessions, !sessions.isEmpty {
                ForEach(sessions) { session in sessionRow(session) }
            } else {
                Text("no sessions").foregroundStyle(.secondary).font(PopupFont.caption)
            }
        }
    }

    private func sessionRow(_ session: SessionHealth) -> some View {
        HStack {
            Text(session.name).lineLimit(1)
            Spacer()
            Text("\(session.ageSeconds / 60) min")
            Text("\(session.rssMB) MB")
            Text("\(Int(session.idleHours())) h idle")
            Text((session.cwd as NSString).lastPathComponent)
                .foregroundStyle(.secondary).help(session.cwd)
        }
        .font(PopupFont.caption).monospacedDigit()
    }
}
