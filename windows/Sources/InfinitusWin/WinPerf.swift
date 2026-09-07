import Foundation
import WinSDK

/// Process cost for `infinitus-win control perf` — the Windows half of
/// the Mac's `{cpuSeconds, rssBytes, heapBytes, threads, uptimeSeconds}`
/// (ControlProtocol.swift). Flat Win32, no COM.
///
/// Windows has no `malloc_zone_statistics`; `PrivateUsage` from
/// `K32GetProcessMemoryInfo` is the heapBytes stand-in. Sample twice
/// and subtract `cpuSeconds` for an idle %.
enum WinPerf {
    struct Snapshot: Encodable {
        let cpuSeconds: Double
        let rssBytes: Double
        let heapBytes: Double
        let threads: Double
        let uptimeSeconds: Double
    }

    /// `uptimeSeconds` is the control server's own clock, matching `status`.
    static func snapshot(uptimeSeconds: Double) -> Snapshot {
        let process = GetCurrentProcess()
        return Snapshot(
            cpuSeconds: cpuSeconds(process),
            rssBytes: memory(process).rss,
            heapBytes: memory(process).heap,
            threads: Double(threadCount()),
            uptimeSeconds: uptimeSeconds)
    }

    // MARK: - CPU

    /// User + kernel time as seconds. FILETIME is 100 ns ticks.
    private static func cpuSeconds(_ process: HANDLE?) -> Double {
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(process, &created, &exited, &kernel, &user) else { return -1 }
        return filetimeSeconds(kernel) + filetimeSeconds(user)
    }

    private static func filetimeSeconds(_ ft: FILETIME) -> Double {
        let ticks = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
        return Double(ticks) / 10_000_000.0
    }

    // MARK: - RSS / private (heap stand-in)

    /// Layout of `PROCESS_MEMORY_COUNTERS_EX` on x64. Two leading DWORDs
    /// fill 8 bytes, then nine SIZE_Ts — 80 bytes, no extra padding.
    private struct MemoryCountersEX {
        var cb: DWORD = 0
        var PageFaultCount: DWORD = 0
        var PeakWorkingSetSize: UInt64 = 0
        var WorkingSetSize: UInt64 = 0
        var QuotaPeakPagedPoolUsage: UInt64 = 0
        var QuotaPagedPoolUsage: UInt64 = 0
        var QuotaPeakNonPagedPoolUsage: UInt64 = 0
        var QuotaNonPagedPoolUsage: UInt64 = 0
        var PagefileUsage: UInt64 = 0
        var PeakPagefileUsage: UInt64 = 0
        var PrivateUsage: UInt64 = 0
    }

    private typealias GetProcessMemoryInfoFn = @convention(c) (
        HANDLE?, UnsafeMutableRawPointer?, DWORD
    ) -> Int32

    private static func memory(_ process: HANDLE?) -> (rss: Double, heap: Double) {
        let fn: GetProcessMemoryInfoFn? =
            proc("KERNEL32.DLL", "K32GetProcessMemoryInfo")
            ?? proc("PSAPI.DLL", "GetProcessMemoryInfo")
        guard let fn else { return (-1, -1) }
        var counters = MemoryCountersEX()
        let cb = DWORD(MemoryLayout<MemoryCountersEX>.size)
        counters.cb = cb
        let ok = withUnsafeMutableBytes(of: &counters) { raw -> Bool in
            fn(process, raw.baseAddress, cb) != 0
        }
        guard ok else { return (-1, -1) }
        return (Double(counters.WorkingSetSize), Double(counters.PrivateUsage))
    }

    // MARK: - threads

    private struct ThreadEntry32 {
        var dwSize: DWORD = 0
        var cntUsage: DWORD = 0
        var th32ThreadID: DWORD = 0
        var th32OwnerProcessID: DWORD = 0
        var tpBasePri: Int32 = 0
        var tpDeltaPri: Int32 = 0
        var dwFlags: DWORD = 0
    }

    private typealias SnapshotFn = @convention(c) (DWORD, DWORD) -> HANDLE
    /// Raw pointer: a Swift struct is not `@convention(c)`-representable.
    private typealias ThreadWalkFn = @convention(c) (HANDLE?, UnsafeMutableRawPointer?) -> Int32

    /// `CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD)` then count rows owned
    /// by this pid. -1 if the walk cannot start (missing export / access).
    private static func threadCount() -> Int {
        let snapThread: DWORD = 0x00000004
        guard let create: SnapshotFn = proc("KERNEL32.DLL", "CreateToolhelp32Snapshot"),
              let first: ThreadWalkFn = proc("KERNEL32.DLL", "Thread32First"),
              let next: ThreadWalkFn = proc("KERNEL32.DLL", "Thread32Next")
        else { return -1 }
        let snap = create(snapThread, 0)
        guard snap != INVALID_HANDLE_VALUE else { return -1 }
        defer { CloseHandle(snap) }
        var entry = ThreadEntry32()
        let size = DWORD(MemoryLayout<ThreadEntry32>.size)
        entry.dwSize = size
        let okFirst = withUnsafeMutableBytes(of: &entry) { first(snap, $0.baseAddress) != 0 }
        guard okFirst else { return -1 }
        let pid = GetCurrentProcessId()
        var count = 0
        repeat {
            if entry.th32OwnerProcessID == pid { count += 1 }
            entry.dwSize = size
        } while withUnsafeMutableBytes(of: &entry) { next(snap, $0.baseAddress) != 0 }
        return count
    }

    // MARK: - GetProcAddress

    /// psapi / tlhelp32 are not in the Swift WinSDK overlay;
    /// `K32GetProcessMemoryInfo` lives in kernel32 on Win7+ (`PSAPI_VERSION > 1`).
    private static func proc<T>(_ module: String, _ name: String) -> T? {
        let wide = Array(module.utf16) + [0]
        let loaded = wide.withUnsafeBufferPointer { GetModuleHandleW($0.baseAddress) }
            ?? wide.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }
        guard let loaded, let raw = name.withCString({ GetProcAddress(loaded, $0) })
        else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }
}
