import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import InfinitusCore
import InfinitusUI

/// One session's recent important messages (#17), chat-style — `GET
/// /sessions/<pid>/tail` polled every 5s while this screen is on screen,
/// with a bottom composer and per-card action buttons (layer 2) that
/// `POST /sessions/<pid>/input`.
struct SessionFeedScreen: View {
    @ObservedObject var model: MirrorModel
    let session: SessionDetail

    @State private var feed: SessionFeed?
    @State private var errorText: String?
    @State private var draft = ""
    @State private var sendingMessage = false
    @State private var messageResult: String?
    @State private var actionSending = false
    @State private var actionResult: String?
    // MARK: attachments (2026-09-03 "add features to allow attachments")
    @State private var attachments: [PendingAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var attachmentError: String?

    /// A picked file, already processed into the exact bytes/mime that
    /// will ride in `SessionInput.Attachment`.
    private struct PendingAttachment: Identifiable {
        let id = UUID()
        let name: String
        let mime: String
        let data: Data
        let thumbnail: UIImage?
    }

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
        .navigationTitle(feed?.name ?? repoName(session.cwd))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The whole header is a tap target into the detail screen
            // (user 2026-09-03: "a more detail screen when tap on its
            // header title") — same NavigationPath the row tap already
            // pushes onto, one level deeper.
            ToolbarItem(placement: .principal) {
                NavigationLink(value: SessionDetailRoute(session: session)) {
                    VStack(spacing: 1) {
                        Text(feed?.name ?? repoName(session.cwd)).font(.headline)
                        Text(feed?.status ?? session.status)
                            .font(.caption2).foregroundStyle(.secondary)
                        if let line = AccountSummaryFormat.headerLine(
                            model.accountSummary(forSessionPid: session.pid)) {
                            HStack(spacing: 4) {
                                Circle().fill(ThemeColor.resolve(line.colorName))
                                    .frame(width: 6, height: 6)
                                Text(line.text)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
        .refreshable { await load() }
        .task {
            // Long-poll loop: each request returns when the transcript
            // changes (or after the Mac's wait cap), so a reply lands
            // within a second of being written. Against a Mac that
            // ignores `since`/`wait` the floor below keeps it a 2 s poll.
            while !Task.isCancelled {
                let started = Date()
                let ok = await load(longPoll: feed?.stamp != nil)
                let elapsed = Date().timeIntervalSince(started)
                let floor: TimeInterval = ok ? 2 : 3
                if elapsed < floor {
                    try? await Task.sleep(nanoseconds: UInt64((floor - elapsed) * 1_000_000_000))
                }
            }
        }
    }

    @discardableResult
    private func load(longPoll: Bool = false) async -> Bool {
        do {
            if longPoll, let since = feed?.stamp {
                do {
                    feed = try await NetworkFleetMirror.shared.sessionTail(
                        pid: Int32(session.pid), limit: 30, since: since,
                        wait: MirrorTransport.tailWaitMax)
                    errorText = nil
                    return true
                } catch {
                    // The pinned route may have died — the plain fetch
                    // below walks every route again.
                }
            }
            feed = try await NetworkFleetMirror.shared.sessionTail(pid: Int32(session.pid), limit: 30)
            errorText = nil
            return true
        } catch {
            errorText = feed == nil ? "couldn't reach the Mac: \(error.localizedDescription)"
                : "offline — showing the last feed"
            return false
        }
    }

    // MARK: - Layer 2: sending in

    private var composer: some View {
        VStack(spacing: 4) {
            if let messageResult {
                Text(messageResult).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(attachments) { attachmentChip($0) } }
                        .padding(.horizontal)
                }
            }
            HStack(spacing: 8) {
                Menu {
                    // A PhotosPicker inside a Menu never presents (the menu
                    // dismisses first — user 2026-09-03 "Choose library
                    // doesn't show anything"); the picker is a modifier
                    // below, flipped from a plain button like the importer.
                    Button { showPhotoPicker = true } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button { showFileImporter = true } label: {
                        Label("Choose File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "paperclip").font(.title2)
                }
                .disabled(sendingMessage || attachments.count >= SessionInput.maxAttachments)
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
                          || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && attachments.isEmpty))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPickedPhotos(items) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
                      maxSelectionCount: SessionInput.maxAttachments, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: Self.allowedFileTypes,
                     allowsMultipleSelection: true) { result in
            addPickedFiles(result)
        }
    }

    private static let allowedFileTypes: [UTType] = [
        .png, .jpeg, .heic, .gif, .pdf, .plainText,
        UTType(mimeType: "image/webp"),
    ].compactMap { $0 }

    @ViewBuilder private func attachmentChip(_ attachment: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.fill").font(.title3)
                        Text(attachment.name).font(.caption2).lineLimit(1)
                    }
                }
            }
            .frame(width: 52, height: 52)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }

    /// PhotosPicker hands over the original bytes (HEIC included); every
    /// image is downscaled to ≤ 2048 px on its long edge and re-encoded
    /// JPEG regardless of source format.
    private func addPickedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard attachments.count < SessionInput.maxAttachments else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data), let jpeg = Self.downscaledJPEG(image) else {
                attachmentError = "couldn't read that photo"
                continue
            }
            guard jpeg.count <= SessionInput.maxAttachmentBytes else {
                attachmentError = "that photo is still \(jpeg.count / 1_048_576) MB after compression — the cap is \(SessionInput.maxAttachmentBytes / 1_048_576) MB"
                continue
            }
            let name = "photo-\(UUID().uuidString.prefix(8)).jpg"
            attachments.append(PendingAttachment(name: name, mime: "image/jpeg",
                                                 data: jpeg, thumbnail: UIImage(data: jpeg)))
        }
        photoPickerItems = []
    }

    private static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat = 2048,
                                       quality: CGFloat = 0.85) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / longest)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: targetSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        // A busy 2048 px frame can still pass the Mac's 5 MiB cap at 0.85;
        // step the quality down before giving up on it.
        for q in [quality, 0.7, 0.55, 0.4] {
            if let data = resized.jpegData(compressionQuality: q),
               data.count <= SessionInput.maxAttachmentBytes { return data }
        }
        return resized.jpegData(compressionQuality: 0.4)
    }

    /// PDFs/text ride as-is (≤ 5 MiB, same cap the Mac enforces) — no
    /// re-encoding, unlike photos.
    private func addPickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            guard attachments.count < SessionInput.maxAttachments else { break }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "couldn't read \(url.lastPathComponent)"
                continue
            }
            guard data.count <= SessionInput.maxAttachmentBytes else {
                attachmentError = "\(url.lastPathComponent) is over 5 MB"
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            guard SessionInput.allowedAttachmentMimes.contains(mime) else {
                attachmentError = "\(url.lastPathComponent) isn't a supported file type"
                continue
            }
            attachments.append(PendingAttachment(name: url.lastPathComponent, mime: mime,
                                                 data: data, thumbnail: nil))
        }
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
        guard !text.isEmpty || !attachments.isEmpty else { return }
        sendingMessage = true
        messageResult = nil
        attachmentError = nil
        let picked = attachments.map {
            SessionInput.Attachment(name: $0.name, mime: $0.mime, data: $0.data)
        }
        Task {
            await send(.init(kind: .message, text: text,
                             attachments: picked.isEmpty ? nil : picked)) { reply in
                if reply.outcome == "delivered" {
                    draft = ""
                    attachments = []
                    messageResult = reply.channel == "socket" ? "sent as a message (no terminal)" : nil
                } else {
                    // The Mac says why ("attachment too large", "unsupported
                    // attachment type"…) — show it, a bare "wasn't valid"
                    // sent the user guessing (2026-09-03).
                    messageResult = reply.detail.map { "\(Self.describe(reply.outcome)) — \($0)" }
                        ?? Self.describe(reply.outcome)
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
                MarkdownText(text: item.text)
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
        case .agent:
            // Sub-agent card, the way Claude Code's own UI lists them
            // (user 2026-09-03 via the phone: "show sub agents like
            // Claude Code rc on mobile").
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(item.agent?.running == true ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.agent.map { "\($0.type) — \($0.description)" } ?? item.text)
                        .font(.subheadline.weight(.semibold))
                    if let agent = item.agent {
                        Text(agentStatus(agent))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func agentStatus(_ agent: SessionFeedItem.Agent) -> String {
        var parts = ["\(agent.toolCalls) tool call\(agent.toolCalls == 1 ? "" : "s")"]
        if let last = agent.lastTool { parts.append("last: \(last)") }
        parts.append(agent.running ? "running" : "done")
        return parts.joined(separator: " · ")
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
