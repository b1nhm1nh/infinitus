import Foundation

/// Client-side mirror of the engine's `_next_recovery` advisory
/// (claude_swap/switcher.py), minus its active-account exclusion.
///
/// The engine skips the active account when ranking who recovers soonest
/// — reasonable for "should the auto-switcher wait on someone else", but
/// wrong for "who does the popup tell the user to wait for": if the
/// active account is itself dead and its last maxed window resets before
/// anyone else's, the engine still names a LATER account (user report
/// 2026-09-02: "loc recovers in 01:07:23" while the active account,
/// deathemperor2nd, actually revived in 27m). We recompute the same
/// ranking over every non-disabled account, active included, and prefer
/// it — it only ever finds a candidate at least as soon as the engine's.
public enum RecoveryMath {
    /// Mirrors `_next_recovery` exactly, without the `row.number == active`
    /// skip. ISO-8601 `resetsAt` strings compare lexicographically, same
    /// as the engine.
    public static func nextRecovery(accounts: [Account]) -> NextRecovery? {
        var best: (key: String, number: Int)?
        for account in accounts {
            if account.disabled == true { continue }
            guard let usage = account.usage else { continue }
            var windows: [UsageWindow] = []
            if let w = usage.fiveHour { windows.append(w) }
            if let w = usage.sevenDay { windows.append(w) }
            windows += usage.scoped ?? []
            let maxed = windows.filter { $0.pct >= 100 }
            if maxed.isEmpty { continue }  // viable — not this advisory's territory
            let resets = maxed.map { $0.resetsAt ?? "" }
            if resets.contains("") { continue }  // a maxed window with no reset can't be ranked
            let key = resets.max()!  // ISO-8601 sorts lexicographically
            if best == nil || key < best!.key {
                best = (key, account.number)
            }
        }
        guard let best else { return nil }
        return NextRecovery(number: best.number, at: best.key)
    }

    /// The value to actually show: the client's superset ranking when it
    /// can rank someone (never later than the engine's, since it considers
    /// strictly more candidates), else the engine's own value. `nil` when
    /// the engine reports `nil` — the "everyone limited" premise comes
    /// from the engine, and this never invents it.
    ///
    /// The engine emits `nextRecovery` whenever it has no OTHER account
    /// to switch to — it never looks at the active one. With the active
    /// account healthy and every spare limited, that read "All accounts
    /// down" over a working fleet (user 2026-09-04). So: no active
    /// account, or an active account that is itself at a limit, else
    /// there is nothing to wait for.
    public static func corrected(engine: NextRecovery?, accounts: [Account],
                                 activeNumber: Int?) -> NextRecovery? {
        guard engine != nil else { return nil }
        if let active = accounts.first(where: { $0.number == activeNumber }),
           !AccountVitals.isDead(active.usage) { return nil }
        return nextRecovery(accounts: accounts) ?? engine
    }
}
