import Foundation

/// `TeamStore` over git plumbing (spec §4.2). The local side is a bare
/// mirror — no working tree, no checkouts: writes build a tree on top of
/// the branch's remote-tracking commit with a private index file and
/// push the new commit; reads use `ls-tree` / `cat-file`. A write that
/// loses a push race fetches and retries once on the new tip; a caller
/// that computed its bytes from what it read (the roster) passes
/// `retryOnRace: false` and gets `raceLost` instead.
///
/// The credential never touches argv: it rides in the child's
/// environment as `INFINITUS_TEAM_TOKEN` and an inline credential helper
/// hands it to git.
public final class TeamGit: TeamStore {
    public static let tokenEnv = "INFINITUS_TEAM_TOKEN"

    public enum GitError: Error {
        case failed(command: String, status: Int32, stderr: String)
        case notOpen
        case badPath(String)
        /// The push was rejected and the caller asked not to retry.
        case raceLost
        /// No subprocesses on this platform (iOS): the phone talks to its
        /// Mac, which holds the mirror.
        case unavailable
    }

    public let dir: URL
    public let remote: String
    private let token: String?
    private let author: String
    private var gitDir: URL { dir.appendingPathComponent("store.git") }
    private var opened = false

    public init(dir: URL, remote: String, token: String?, author: String) {
        self.dir = dir; self.remote = remote; self.token = token; self.author = author
    }

    /// Creates the bare mirror on first use and fetches only then: an
    /// existing mirror opens offline and callers `sync()` when they want
    /// the network (so `team status` never waits on a remote).
    public func open() throws {
        let fresh = !FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("HEAD").path)
        if fresh {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try run(["init", "--bare", "-q", gitDir.path], useGitDir: false)
            _ = try run(["remote", "add", "origin", remote])
        }
        opened = true
        if fresh { try sync() }
    }

    // MARK: TeamStore

    public func sync() throws {
        _ = try run(["fetch", "-q", "--prune", "origin", "+refs/heads/*:refs/remotes/origin/*"])
    }

    public func put(_ path: String, _ data: Data) throws { try putAll([path: data]) }

    public func delete(_ path: String) throws { try putAll([path: nil]) }

    public func putAll(_ writes: [String: Data?]) throws { try putAll(writes, retryOnRace: true) }

    /// `retryOnRace: false` refuses to rebuild the same bytes on the
    /// winner's tip — for an object computed from what was read (the
    /// roster) that would silently discard the other writer's change.
    public func putAll(_ writes: [String: Data?], retryOnRace: Bool) throws {
        guard opened else { throw GitError.notOpen }
        var byBranch: [String: [(String, Data?)]] = [:]
        for (path, data) in writes {
            guard let (branch, rest) = StorePath.branch(of: path) else { throw GitError.badPath(path) }
            byBranch[branch, default: []].append((rest, data))
        }
        for (branch, items) in byBranch {
            do {
                try commitAndPush(branch: branch, items: items)
            } catch GitError.failed(let command, _, _) where command.hasPrefix("push") {
                // Someone else (another device of ours) pushed first: rebuild on the new tip.
                guard retryOnRace else { throw GitError.raceLost }
                try sync()
                try commitAndPush(branch: branch, items: items)
            }
        }
    }

    public func get(_ path: String) throws -> Data? {
        guard opened else { throw GitError.notOpen }
        guard let (branch, rest) = StorePath.branch(of: path) else { throw GitError.badPath(path) }
        guard let head = try head(of: branch) else { return nil }
        do {
            return try run(["cat-file", "blob", "\(head):\(rest)"])
        } catch GitError.failed { return nil }
    }

    public func list(_ prefix: String) throws -> [StoreEntry] {
        guard opened else { throw GitError.notOpen }
        var out: [StoreEntry] = []
        for branch in try branches() {
            guard let head = try head(of: branch) else { continue }
            for entry in try tree(commit: head, branch: branch) where entry.path.hasPrefix(prefix) {
                out.append(entry)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    public func changes(since: StoreCursor?) throws -> ([StoreEntry], StoreCursor) {
        guard opened else { throw GitError.notOpen }
        var out: [StoreEntry] = []
        var cursor = StoreCursor()
        for branch in try branches() {
            guard let head = try head(of: branch) else { continue }
            cursor.heads[branch] = head
            if let old = since?.heads[branch] {
                if old == head { continue }
                let text = String(decoding: try run(["diff-tree", "-r", "--name-only", "--diff-filter=AM", old, head]), as: UTF8.self)
                let changed = Set(text.split(separator: "\n").map(String.init))
                out += try tree(commit: head, branch: branch).filter { changed.contains(String($0.path.dropFirst(branch.count + 1))) }
            } else {
                out += try tree(commit: head, branch: branch)
            }
        }
        return (out.sorted { $0.path < $1.path }, cursor)
    }

    // MARK: plumbing

    private func branches() throws -> [String] {
        let text = String(decoding: try run(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/"]), as: UTF8.self)
        return text.split(separator: "\n").map { String($0.dropFirst("origin/".count)) }
    }

    private func head(of branch: String) throws -> String? {
        do {
            return String(decoding: try run(["rev-parse", "--verify", "-q", "refs/remotes/origin/\(branch)"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.failed { return nil }
    }

    /// `ls-tree -r -l` lines: `<mode> blob <sha> <size>\t<path>`.
    private func tree(commit: String, branch: String) throws -> [StoreEntry] {
        let text = String(decoding: try run(["ls-tree", "-r", "-l", commit]), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let meta = line[line.startIndex..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard meta.count == 4, meta[1] == "blob", let size = Int(meta[3]) else { return nil }
            return StoreEntry(path: branch + "/" + line[line.index(after: tab)...], size: size, version: String(meta[2]))
        }
    }

    private func commitAndPush(branch: String, items: [(String, Data?)]) throws {
        let parent = try head(of: branch)
        let index = dir.appendingPathComponent("index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = [ "GIT_INDEX_FILE": index.path ]
        if let parent { _ = try run(["read-tree", parent], env: env) }
        for (rest, data) in items {
            if let data {
                let blob = String(decoding: try run(["hash-object", "-w", "--stdin"], stdin: data), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try run(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(rest)"], env: env)
            } else {
                // Removal without a work tree: a zero-mode, null-sha entry
                // through --index-info drops the path from the private index.
                let line = Data("0 0000000000000000000000000000000000000000\t\(rest)\n".utf8)
                _ = try run(["update-index", "--index-info"], stdin: line, env: env)
            }
        }
        let treeSha = String(decoding: try run(["write-tree"], env: env), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var commitArgs = ["commit-tree", treeSha, "-m", items.map(\.0).sorted().joined(separator: "\n")]
        if let parent { commitArgs += ["-p", parent] }
        let commit = String(decoding: try run(commitArgs, env: [
            "GIT_AUTHOR_NAME": "Infinitus", "GIT_AUTHOR_EMAIL": "\(author)@infinitus.run",
            "GIT_COMMITTER_NAME": "Infinitus", "GIT_COMMITTER_EMAIL": "\(author)@infinitus.run",
        ]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["push", "-q", "origin", "\(commit):refs/heads/\(branch)"])
        _ = try run(["update-ref", "refs/remotes/origin/\(branch)", commit])
    }

    /// Runs git synchronously. Callers are the CLI (blocking is fine) and
    /// the app's background publish task (never the main thread).
    @discardableResult
    private func run(_ args: [String], stdin: Data? = nil, env extra: [String: String] = [:],
                     useGitDir: Bool = true) throws -> Data {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // Foundation has no Process here; InfinitusCore is linked into the
        // phone app, which never drives git itself (spec §6.2: the phone
        // hands team work to its Mac over the mirror).
        throw GitError.unavailable
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var argv = ["git"]
        if useGitDir { argv += ["--git-dir", gitDir.path] }
        if token != nil {
            argv += ["-c", "credential.helper=",
                     "-c", "credential.helper=!f() { echo username=infinitus; echo \"password=$\(Self.tokenEnv)\"; }; f"]
        }
        argv += args
        p.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        if let token { env[Self.tokenEnv] = token }
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        if let stdin {
            let input = Pipe()
            p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        } else {
            p.standardInput = FileHandle.nullDevice
            try p.run()
        }
        // Drain before waiting so a large blob can't deadlock on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitError.failed(command: args.joined(separator: " "), status: p.terminationStatus,
                                  stderr: String(decoding: errData, as: UTF8.self))
        }
        return data
        #endif
    }
}
