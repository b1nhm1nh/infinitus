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
                    PhotosPicker(selection: $photoPickerItems,
                                maxSelectionCount: SessionInput.maxAttachments,
                                matching: .images) {
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
        return resized.jpegData(compressionQuality: quality)
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
        }
    }

    private func repoName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
