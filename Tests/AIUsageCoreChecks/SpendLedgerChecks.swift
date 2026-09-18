import AIUsageCore
import Foundation

enum SpendLedgerChecks {
    private static func at(_ hours: Double) -> Date { Date(timeIntervalSince1970: hours * 3600) }

    static func run() {
        collapsesUnchangedSamples()
        spendIgnoresTopUps()
        burnRateNeedsHistory()
        runoutFromRate()
        pruneKeepsBaseline()
    }

    static func collapsesUnchangedSamples() {
        var ledger = SpendLedger()
        ledger.record(balance: 100, at: at(0))
        ledger.record(balance: 100, at: at(1))
        ledger.record(balance: 100, at: at(2))
        ledger.record(balance: 99.5, at: at(3))
        Harness.equal(ledger.samples.count, 2, "identical balances collapse")
        Harness.equal(ledger.lastObservedAt, at(3), "last observation tracked")
        ledger.record(balance: 98, at: at(2.5))
        Harness.equal(ledger.samples.count, 2, "out-of-order sample ignored")
    }

    static func spendIgnoresTopUps() {
        var ledger = SpendLedger()
        ledger.record(balance: 100, at: at(0))
        ledger.record(balance: 90, at: at(5))     // spent 10
        ledger.record(balance: 190, at: at(6))    // top-up 100
        ledger.record(balance: 185, at: at(10))   // spent 5
        Harness.close(ledger.spent(from: at(0), to: at(10)), 15, "spend sums decreases only")
        Harness.close(ledger.toppedUp(from: at(0), to: at(10)), 100, "top-ups sum increases only")
        Harness.close(ledger.spent(from: at(5), to: at(10)), 5, "range is (from, to]")
        Harness.close(ledger.spent(from: at(4), to: at(5)), 10, "change point at `to` is included")
    }

    static func burnRateNeedsHistory() {
        var ledger = SpendLedger()
        ledger.record(balance: 100, at: at(0))
        ledger.record(balance: 99, at: at(1))
        Harness.check(ledger.burnRatePerDay(days: 7, now: at(2)) == nil, "2h of history is too little")
        ledger.record(balance: 88, at: at(24))
        // 12 spent over 24h with 7-day lookback clipped to the 24h of history → 12/day.
        Harness.close(ledger.burnRatePerDay(days: 7, now: at(24)) ?? -1, 12, "rate over actual history span")
        // Over a trailing 12h: only the change at 24h (11) counts, span 12h → 22/day.
        Harness.close(ledger.burnRatePerDay(days: 0.5, now: at(24)) ?? -1, 22, "rate over trailing window")
    }

    static func runoutFromRate() {
        var ledger = SpendLedger()
        ledger.record(balance: 30, at: at(0))
        Harness.equal(ledger.runoutDate(ratePerDay: 10, now: at(0)), at(72), "30 at 10/day runs out in 3 days")
        Harness.check(ledger.runoutDate(ratePerDay: 0, now: at(0)) == nil, "zero rate → no runout")
        Harness.check(ledger.runoutDate(ratePerDay: nil, now: at(0)) == nil, "unknown rate → no runout")
    }

    static func pruneKeepsBaseline() {
        var ledger = SpendLedger()
        for h in [0, 10, 20, 30, 40] { ledger.record(balance: 100 - Double(h), at: at(Double(h))) }
        ledger.prune(before: at(25))
        Harness.equal(ledger.samples.map(\.at), [at(20), at(30), at(40)], "keeps last pre-cutoff sample as baseline")
        Harness.close(ledger.spent(from: at(25), to: at(40)), 20, "spend after cutoff still computable")
    }
}
