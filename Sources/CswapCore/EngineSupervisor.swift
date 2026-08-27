import Foundation

/// Assembles NDJSON lines from pipe chunks and remembers whether an
/// engine-refused event went by. Mutated from the pipe's readability
/// handler and read from the termination handler — two GCD threads, hence
/// the lock (the handlers themselves are each serial).
private final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var refused = false

    func feed(_ chunk: Data, onLine: (EventLine) -> Void) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            let line = EventFeed.decode(line: String(decoding: lineData, as: UTF8.self))
            if case .event(let e) = line, e.kind == "engine-refused" { refused = true }
            onLine(line)
        }
    }

    var sawRefusal: Bool { lock.lock(); defer { lock.unlock() }; return refused }
}

/// Supervises the one engine: `cswap auto --json` as a child process
/// (spec §2 — the app hosts no engine of its own).
///
/// Restarts on exit with SupervisorBackoff. Lines stream to `onLine` on an
/// arbitrary thread; the UI layer marshals. `engine-refused` means another
/// host (TUI, a stray `cswap auto`) already owns the store's engine mutex —
/// surfaced as a state, not retried hot, since the refusal is instant and
/// hammering it would spin.
public actor EngineSupervisor {
    public enum State: Sendable, Equatable {
        case stopped
        case running(pid: Int32)
        case backingOff(seconds: Double)
        case refused          // another engine holds the mutex
        case schemaMismatch(Int)
    }

    private let binaryPath: String
    private let onLine: @Sendable (EventLine) -> Void
    private let onState: @Sendable (State) -> Void
    private var process: Process?
    private var backoff = SupervisorBackoff()
    private var stopping = false

    public init(
        binaryPath: String,
        onLine: @escaping @Sendable (EventLine) -> Void,
        onState: @escaping @Sendable (State) -> Void
    ) {
        self.binaryPath = binaryPath
        self.onLine = onLine
        self.onState = onState
    }

    public func start() {
        stopping = false
        spawn()
    }

    public func stop() {
        stopping = true
        process?.terminate()
        process = nil
        onState(.stopped)
    }

    private func spawn() {
        guard !stopping else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = ["auto", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()

        let assembler = LineAssembler()
        let onLine = self.onLine
        pipe.fileHandleForReading.readabilityHandler = { handle in
            assembler.feed(handle.availableData, onLine: onLine)
        }

        let started = Date()
        p.terminationHandler = { [weak self] proc in
            proc.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
            Task { [weak self] in
                await self?.childExited(
                    cleanSeconds: Date().timeIntervalSince(started),
                    refused: assembler.sawRefusal
                )
            }
        }

        do {
            try p.run()
            process = p
            onState(.running(pid: p.processIdentifier))
        } catch {
            onState(.backingOff(seconds: scheduleRespawn()))
        }
    }

    private func childExited(cleanSeconds: Double, refused: Bool) {
        process = nil
        guard !stopping else { return }
        if refused {
            // Instant exit by design; retrying hot would spin. The user
            // resolves it (quit the TUI / stray auto) and hits Start.
            onState(.refused)
            return
        }
        backoff.noteExit(afterCleanSeconds: cleanSeconds)
        onState(.backingOff(seconds: scheduleRespawn()))
    }

    private func scheduleRespawn() -> Double {
        let delay = backoff.nextDelay()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.spawn()
        }
        return delay
    }
}
