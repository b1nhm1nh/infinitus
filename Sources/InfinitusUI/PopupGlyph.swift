import Foundation

/// Text-vs-emoji presentation shim (#9 phase D3). Themes lean on Unicode
/// symbols that carry a text glyph by default on macOS/AppKit (⚔ U+2694,
/// ⏸ U+23F8 — "Emoji" property but not "Emoji_Presentation") but that iOS
/// upgrades to a full-color emoji glyph unless told otherwise. Wrapping a
/// theme string in `PopupGlyph.text` appends the text-presentation
/// selector (U+FE0E) to every such scalar so the two platforms draw the
/// same monochrome glyph. True emoji (👑, 🎲, 💀 — Emoji_Presentation
/// already true) are left untouched, since those already render as emoji
/// on both platforms and match. On macOS this is the identity function —
/// the mac popup must stay bit-identical.
public enum PopupGlyph {
    public static func text(_ s: String) -> String {
        #if os(macOS)
        return s
        #else
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            out.append(scalar)
            guard scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation else { continue }
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if next?.value != 0xFE0F, next?.value != 0xFE0E {
                out.append(Unicode.Scalar(0xFE0E)!)
            }
        }
        return String(out)
        #endif
    }
}
