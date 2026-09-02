import SwiftUI
import InfinitusCore

/// One session's recent important messages (#17), chat-style — `GET
/// /sessions/<pid>/tail` polled every 5s while this screen is on screen,
/// with a bottom composer and per-card action buttons (layer 2) that
/// `POST /sessions/<pid>/input`.
struct SessionFeedScreen: View {
    let session: SessionDetail

    @State private var feed: SessionFeed?
    @State private var errorText: String?
    @State private var draft = ""
    @State private var sendingMessage = false
    @State private var messageResult: String?
    @State private var actionSending = false
    @State private var actionResult: String?
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
                    VStack(alignment: .leading, spacing: 6) {
                        row(item)
                        if index == (feed?.items.count ?? 0) - 1 {
                            actionRow(item)
                        }
                    }
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
        .safeAreaInset(edge: .bottom) { composer }
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

    // MARK: - Layer 2: sending in

    private var composer: some View {
        VStack(spacing: 4) {
            if let messageResult {
                Text(messageResult).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            HStack(spacing: 8) {
                TextField("Reply…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sendingMessage)
                Button(action: sendMessage) {
                    if sendingMessage {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .disabled(sendingMessage
                          || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder private func actionRow(_ item: SessionFeedItem) -> some View {
        switch item.kind {
        case .permission:
            HStack(spacing: 8) {
                Button("Yes") { sendKey("1") }.buttonStyle(.borderedProminent)
                Button("No") { sendKey("3") }.buttonStyle(.bordered)
                if actionSending { ProgressView() }
            }
            .disabled(actionSending)
            if let actionResult { Text(actionResult).font(.caption).foregroundStyle(.secondary) }
        case .question:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((item.options ?? []).enumerated()), id: \.offset) { i, option in
                    Button(option) { sendKey(String(i + 1)) }.buttonStyle(.bordered)
                }
                if actionSending { ProgressView() }
            }
            .disabled(actionSending)
            if let actionResult { Text(actionResult).font(.caption).foregroundStyle(.secondary) }
        default:
            EmptyView()
        }
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendingMessage = true
        messageResult = nil
        Task {
            await send(.init(kind: .message, text: text)) { reply in
                if reply.outcome == "delivered" {
                    draft = ""
                    messageResult = reply.channel == "socket" ? "sent as a message (no terminal)" : nil
                } else {
                    messageResult = Self.describe(reply.outcome)
                }
            } onFailure: {
                messageResult = "couldn't reach the Mac"
            } finished: {
                sendingMessage = false
            }
        }
    }

    private func sendKey(_ key: String) {
        actionSending = true
        actionResult = nil
        Task {
            await send(.init(kind: .key, text: key)) { reply in
                actionResult = reply.outcome == "delivered" ? nil : Self.describe(reply.outcome)
            } onFailure: {
                actionResult = "couldn't reach the Mac"
            } finished: {
                actionSending = false
            }
        }
    }

    private func send(_ request: SessionInput.Request, onReply: @escaping (SessionInput.Reply) -> Void,
                      onFailure: @escaping () -> Void, finished: @escaping () -> Void) async {
        do {
            let reply = try await NetworkFleetMirror.shared.sessionInput(pid: Int32(session.pid),
                                                                         request: request)
            onReply(reply)
        } catch {
            onFailure()
        }
        finished()
        await load()
    }

    private static func describe(_ outcome: String) -> String {
        switch outcome {
        case "running": return "session is mid-turn — try again when it's waiting"
        case "noSurface": return "no terminal found for this session"
        case "noChannel": return "no terminal or messaging channel for this session"
        case "captured": return "a menu is on screen — try again"
        case "rejected": return "that wasn't a valid reply"
        default: return outcome
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
