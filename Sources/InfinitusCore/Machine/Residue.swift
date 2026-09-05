import Foundation

/// What sessions leave behind (#115), reclaimable only by the
/// owner-dead rule: the process that made it is gone, or the session
/// it belonged to is. Never by age alone.
public enum Residue {
    public struct Item: Equatable, Sendable, Codable, Identifiable {
        public let path: String
        public let kind: String
        public let bytes: Int
        public var id: String { path }
        public init(path: String, kind: String, bytes: Int) { self.path = path; self.kind = kind; self.bytes = bytes }
    }

    /// `/tmp/cc-socks/<pid>.sock` whose pid no longer runs.
    public static func staleSockets(dir: String, alive: (Int) -> Bool, fm: FileManager = .default) -> [Item] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".sock"), let pid = Int(name.dropLast(5)), !alive(pid) else { return nil }
            return Item(path: dir + "/" + name, kind: "socket", bytes: 0)
        }
    }

    /// `~/.claude/session-env/<session id>` dirs whose session is gone.
    public static func staleSessionEnvs(dir: String, liveSessionIds: Set<String>, fm: FileManager = .default) -> [Item] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { !liveSessionIds.contains($0) && !$0.hasPrefix(".") }
            .map { Item(path: dir + "/" + $0, kind: "session-env", bytes: 0) }
    }

    /// `mktemp` leftovers (`tmp.XXXXXXXXXX`) older than `minAge` that no
    /// process holds open. `openPaths` comes from one `lsof` call at
    /// reclaim time — never from the sampler.
    public static func orphanTemps(dir: String, minAge: TimeInterval = 3600, openPaths: Set<String>,
                                   now: Date = Date(), limit: Int = 20_000, fm: FileManager = .default) -> [Item] {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Item] = []
        let held = Set(openPaths.map(canonical))
        for name in names where name.hasPrefix("tmp.") && name.count == 14 {
            let path = dir + "/" + name
            let mine = canonical(path)
            guard !held.contains(mine), !held.contains(where: { $0.hasPrefix(mine + "/") }),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > minAge else { continue }
            out.append(Item(path: path, kind: "temp", bytes: (attrs[.size] as? Int) ?? 0))
            if out.count >= limit { break }
        }
        return out
    }

    /// `TMPDIR` ends in `/` and lsof reports `/private/var/…` for
    /// `/var/…`; both sides of the held-file check go through this.
    public static func canonical(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    #if canImport(Darwin) && !os(iOS)
    /// Paths open under `dir`, from `lsof +D` (one call; can take a while
    /// on a wedged directory, so callers give it a deadline). `nil` when
    /// lsof did not finish — lsof exits 1 for "nothing open" too, so the
    /// shell marker is what tells a clean run from a killed one; callers
    /// skip the temp reclaim on nil rather than reclaim unprotected.
    public static func openPaths(under dir: String, timeout: TimeInterval = 60) -> Set<String>? {
        let script = "/usr/sbin/lsof -Fn +D \"$1\" 2>/dev/null; echo __lsof_done__"
        guard let out = try? Subprocess.run("/bin/sh", ["-c", script, "sh", dir], timeout: timeout),
              out.contains("__lsof_done__") else { return nil }
        return Set(out.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
    }
    #endif

    /// Removes exactly the listed items. Returns what could not go.
    @discardableResult
    public static func reclaim(_ items: [Item], fm: FileManager = .default) -> [Item] {
        items.filter { item in
            (try? fm.removeItem(atPath: item.path)) == nil
        }
    }

    /// Bytes under a directory, shallow-summed (for the sizes the tab
    /// reports: transcripts, plugin cache, claude-mem).
    public static func size(of dir: String, fm: FileManager = .default) -> Int {
        guard let walk = fm.enumerator(atPath: dir) else { return 0 }
        var total = 0
        for case let rel as String in walk {
            if let size = (try? fm.attributesOfItem(atPath: dir + "/" + rel))?[.size] as? Int { total += size }
        }
        return total
    }
}
