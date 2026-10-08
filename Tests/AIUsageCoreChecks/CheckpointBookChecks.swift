import AIUsageCore
import Foundation

enum CheckpointBookChecks {
    private static let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private static let resets = t0.addingTimeInterval(4 * 86400)

    private static func week(_ used: Double, resets: Date = resets, at: Date = t0) -> UsageWindow {
        UsageWindow(kind: .sevenDay, usedPercent: used, resetsAt: resets, observedAt: at)
    }

    static func run() {
        repaceAppliesToItsInstanceOnly()
        manualWinsOverACreditAndClearFallsBack()
        creditVoidsTheManualPoint()
        creditsAreDetectedFromConsecutiveReadings()
        canRepaceNeedsALiveWindowWithQuota()
        persistenceRoundTrips()
    }

    static func repaceAppliesToItsInstanceOnly() {
        var book = CheckpointBook()
        book.repace(week(60), now: t0)
        Harness.equal(book.checkpoint(for: week(62)), PaceCheckpoint(at: t0, usedPercent: 60), "same instance")
        Harness.equal(book.checkpoint(for: week(62, resets: resets.addingTimeInterval(1))), PaceCheckpoint(at: t0, usedPercent: 60), "reset jitter tolerated")
        Harness.equal(book.checkpoint(for: week(5, resets: resets.addingTimeInterval(7 * 86400))), nil, "next instance")
        Harness.equal(book.checkpoint(for: week(40)), nil, "usage below the origin")
        Harness.equal(book.checkpoint(for: nil), nil, "no window")
        Harness.equal(book.isAutomatic(week(62)), false, "user's own")
    }

    static func manualWinsOverACreditAndClearFallsBack() {
        var book = CheckpointBook()
        book.recordCredit(in: week(0), at: t0)
        Harness.equal(book.isAutomatic(week(10)), true, "credit origin is automatic")
        book.repace(week(10), now: t0.addingTimeInterval(3600))
        Harness.equal(book.checkpoint(for: week(12))?.usedPercent, 10, "manual wins")
        Harness.equal(book.isAutomatic(week(12)), false, "manual is not automatic")
        book.clear(.sevenDay)
        Harness.equal(book.checkpoint(for: week(12)), PaceCheckpoint(at: t0, usedPercent: 0), "falls back to the credit")
    }

    static func creditVoidsTheManualPoint() {
        var book = CheckpointBook()
        book.repace(week(60), now: t0)
        book.recordCredit(in: week(0, at: t0.addingTimeInterval(600)), at: t0.addingTimeInterval(600))
        Harness.equal(book.manual[.sevenDay], nil, "manual point deleted")
        Harness.equal(book.checkpoint(for: week(70))?.usedPercent, 0, "credit origin, even above the old base")
    }

    static func creditsAreDetectedFromConsecutiveReadings() {
        var book = CheckpointBook()
        let later = t0.addingTimeInterval(300)
        book.recordCredits(from: [week(50)], to: [week(47, at: later)])
        Harness.equal(book.restores.isEmpty, true, "a small dip is noise")
        book.recordCredits(from: [week(50)], to: [week(5, resets: resets.addingTimeInterval(7 * 86400), at: later)])
        Harness.equal(book.restores.isEmpty, true, "a new instance is a reset, not a credit")
        book.recordCredits(from: [], to: [week(0, at: later)])
        Harness.equal(book.restores.isEmpty, true, "no previous reading")
        book.recordCredits(from: [week(50)], to: [week(0, at: later)])
        Harness.equal(book.restores[.sevenDay]?.checkpoint, PaceCheckpoint(at: later, usedPercent: 0), "credit at the newer reading")
    }

    static func canRepaceNeedsALiveWindowWithQuota() {
        Harness.check(CheckpointBook.canRepace(week(60), now: t0), "live window")
        Harness.check(!CheckpointBook.canRepace(week(99), now: t0), "at target")
        Harness.check(!CheckpointBook.canRepace(week(60), now: resets), "window over")
        Harness.check(!CheckpointBook.canRepace(nil, now: t0), "no window")
    }

    static func persistenceRoundTrips() {
        var book = CheckpointBook()
        book.repace(week(60), now: t0)
        Harness.equal(CheckpointBook.decode(CheckpointBook.encode(book.manual)), book.manual, "round trip")
        // The format the app wrote before the type existed: keyed by raw value.
        let legacy = #"{"seven_day":{"resetsAt":0,"checkpoint":{"at":0,"usedPercent":60}}}"#
        Harness.equal(CheckpointBook.decode(Data(legacy.utf8))[.sevenDay]?.checkpoint.usedPercent, 60, "legacy format")
        Harness.equal(CheckpointBook.decode(nil).isEmpty, true, "nothing stored")
    }
}
