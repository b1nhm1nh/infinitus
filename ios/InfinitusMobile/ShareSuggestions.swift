import InfinitusCore
import InfinitusUI
import Intents
import UIKit

/// Sessions in the share sheet's suggestions row (#82, user 2026-09-05:
/// "each conversation is a session so that I can share anything to
/// agents"): one INSendMessageIntent donation per live session, named
/// after it, wearing the theme's glyph; the share extension declares
/// the intent and preselects the session a tapped suggestion names.
/// A session is identified by its working directory, which survives a
/// restart where the pid does not.
@MainActor
enum ShareSuggestions {
    static let maxDonations = 8
    private static var donated: [String: String] = [:]   // cwd → name

    static func sync(sessions: [SessionDetail], name: (Int) -> String?, theme: RowTheme) {
        var wanted: [String: String] = [:]
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }).prefix(maxDonations) {
            wanted[session.cwd] = name(session.pid) ?? URL(fileURLWithPath: session.cwd).lastPathComponent
        }
        guard wanted != donated else { return }
        for cwd in donated.keys where wanted[cwd] == nil {
            INInteraction.delete(with: Self.group(cwd))
        }
        let image = glyphImage(theme)
        for (cwd, name) in wanted where donated[cwd] != name {
            let handle = INPersonHandle(value: cwd, type: .unknown)
            let person = INPerson(personHandle: handle, nameComponents: nil, displayName: name,
                                  image: image, contactIdentifier: nil, customIdentifier: cwd)
            let intent = INSendMessageIntent(recipients: [person], outgoingMessageType: .outgoingMessageText,
                                             content: nil, speakableGroupName: INSpeakableString(spokenPhrase: name),
                                             conversationIdentifier: cwd, serviceName: "Infinitus", sender: nil,
                                             attachments: nil)
            if let image { intent.setImage(image, forParameterNamed: \.speakableGroupName) }
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.groupIdentifier = Self.group(cwd)
            interaction.donate()
        }
        donated = wanted
    }

    private static func group(_ cwd: String) -> String { "session:" + cwd }

    /// The theme's glyph on its tint, 180 px — what the row shows.
    private static func glyphImage(_ theme: RowTheme) -> INImage? {
        let glyph = theme.plain ? "∞" : PopupGlyph.text(theme.activeIcon.isEmpty ? theme.sessionLabel : theme.activeIcon)
        let size = CGSize(width: 180, height: 180)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(ThemeColor.flash(theme)).withAlphaComponent(0.25).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 96)]
            let text = NSAttributedString(string: glyph, attributes: attributes)
            let bounds = text.boundingRect(with: size, options: .usesLineFragmentOrigin, context: nil)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
        return image.pngData().map { INImage(imageData: $0) }
    }
}
