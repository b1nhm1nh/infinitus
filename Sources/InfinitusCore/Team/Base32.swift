import Foundation

/// RFC 4648 base32, lowercase, unpadded — the alphabet a `kid` is written
/// in (26 chars for 16 bytes). Encode only; nothing decodes a kid.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func encode(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
}
