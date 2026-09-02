import SwiftUI
import InfinitusCore

/// One session's recent important messages (#17 layer 1), chat-style and
/// read-only — `GET /sessions/<pid>/tail` polled every 5s while this
/// screen is on screen. Layer 2 turns the question/permission cards into
/// buttons; for now they're just shown.
struct SessionFeedScreen: View {
    let session: SessionDetail

    @State private var feed: SessionFeed?
    @State private var errorText: String?
    private let pollInterval: UInt64 = 5 * 1_000_000_000

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if feed?.waiting == true {
                    Label("Waiting on you", systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange)
                        .listRowSeparator(.hidden)
                }
                ForEach(Array((feed?.items ?? []).enumerated()), id: \.offset) { index, item in
                    row(item)
                        .id(index)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                if let errorText {
                    Text(errorText)
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .onChange(of: feed?.items.count) { _, _ in
                guard let last = feed?.items.indices.last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .navigationTitle(repoName(session.cwd))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(repoName(session.cwd)).font(.headline)
                    Text(feed?.status ?? session.status)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    private func load() async {
        do {
            feed = try await NetworkFleetMirror.shared.sessionTail(pid: Int32(session.pid), limit: 30)
            errorText = nil
        } catch {
            errorText = feed == nil ? "couldn't reach the Mac: \(error.localizedDescription)"
                : "offline — showing the last feed"
        }
    }

    @ViewBuilder private func row(_ item: SessionFeedItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant, .result:
            HStack {
                Text(item.text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2)
                Text("\(item.toolName ?? "Tool") · \(item.text)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(.quaternary, in: Capsule())
        case .permission:
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(item.toolName ?? "Tool") wants to run: \(item.text)")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        case .question:
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text).font(.subheadline.weight(.semibold))
                ForEach(item.options ?? [], id: \.self) { option in
                    Text("• \(option)").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        case .limit:
            Label(item.text, systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
