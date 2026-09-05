import Foundation

/// Spec §7 transcripts: append-only chunks of at most `maxChunkBytes` of
/// NEW complete lines since the last chunk, each line redacted before
/// it is counted. Ciphertext never delta-compresses, so chunks are
/// what keeps the store's growth linear in what was actually written.
public enum TeamChunker {
    public static let maxChunkBytes = 1 << 20
    /// Bytes read per call: a first publish of a hundreds-of-MB
    /// transcript proceeds in slices, one per publish.
    public static let readCap = 64 << 20
    private static let newline = UInt8(ascii: "\n")

    /// Chunks of the complete lines after byte `offset`, and the offset
    /// just past the last line consumed. A line without its newline
    /// waits for the next call; a line above `maxBytes` is its own chunk.
    public static func chunks(of url: URL, from offset: Int, maxBytes: Int = maxChunkBytes,
                              readCap: Int = readCap, redact: (String) -> String) throws -> (chunks: [Data], offset: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: readCap), let lastNewline = data.lastIndex(of: newline) else {
            return ([], offset)
        }
        let complete = data[data.startIndex...lastNewline]
        var chunks: [Data] = []
        var current = Data()
        var start = complete.startIndex
        while start < complete.endIndex {
            let end = complete[start...].firstIndex(of: newline) ?? complete.endIndex
            var line = Data(redact(String(decoding: complete[start..<end], as: UTF8.self)).utf8)
            line.append(newline)
            if !current.isEmpty, current.count + line.count > maxBytes {
                chunks.append(current)
                current = Data()
            }
            current.append(line)
            start = end + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return (chunks, offset + complete.count)
    }
}
