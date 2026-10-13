import AIUsageCore
import Foundation

enum DesktopHistoryChecks {
    // Shape of a real file (desktop app, October 2026); orgs and values made up.
    static let historyJSON = """
    {"version":2,"samples":[
      {"t":1000000,"org":"org-a","u":{"fh":10,"sd":20}},
      {"t":3000000,"org":"org-b","u":{"fh":70,"sd":80}},
      {"t":2000000,"org":"org-a","u":{"fh":14,"sd":21}},
      {"t":2500000,"org":"org-a","u":{}}
    ]}
    """

    static func run() {
        parsesTheNewestSampleOfTheOrganization()
        rejectsAnotherVersion()
        updatesAHeldWindowInstance()
        ignoresSamplesOutsideTheHeldInstance()
        ignoresSamplesOlderThanTheHeldReading()
        aDesktopDropIsACredit()
        cannotStartAWindowOnItsOwn()
    }

    private static func held(fiveHour: Double, observedAt t: TimeInterval, statuslineAt: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(source: .statusline, observedAt: Date(timeIntervalSince1970: statuslineAt), windows: [
            UsageWindow(kind: .fiveHour, usedPercent: fiveHour, resetsAt: Date(timeIntervalSince1970: 10000),
                        observedAt: Date(timeIntervalSince1970: t)),
        ])
    }

    private static func sample(at t: TimeInterval, fiveHour: Double) -> DesktopUsageSample {
        DesktopUsageSample(observedAt: Date(timeIntervalSince1970: t), usedPercent: [.fiveHour: fiveHour])
    }

    static func parsesTheNewestSampleOfTheOrganization() {
        let latest = DesktopHistoryParser.latest(Data(historyJSON.utf8), org: "org-a")
        Harness.equal(latest?.observedAt, Date(timeIntervalSince1970: 2000), "newest non-empty sample of org-a, milliseconds → seconds")
        Harness.equal(latest?.usedPercent[.fiveHour], 14, "fh is the 5-hour window")
        Harness.equal(latest?.usedPercent[.sevenDay], 21, "sd is the 7-day window")
        Harness.check(DesktopHistoryParser.latest(Data(historyJSON.utf8), org: "org-c") == nil, "an unknown org has no data")
    }

    static func rejectsAnotherVersion() {
        let json = historyJSON.replacingOccurrences(of: "\"version\":2", with: "\"version\":3")
        Harness.check(DesktopHistoryParser.latest(Data(json.utf8), org: "org-a") == nil, "an unknown version is no data")
    }

    static func updatesAHeldWindowInstance() {
        // Idle sessions moved the snapshot's own time past the sample; the window's reading is older.
        let snap = held(fiveHour: 10, observedAt: 3000, statuslineAt: 6000)
        let updated = snap.applying(sample(at: 5000, fiveHour: 25))
        Harness.equal(updated?.window(.fiveHour)?.usedPercent, 25, "a newer desktop reading is taken")
        Harness.equal(updated?.window(.fiveHour)?.resetsAt, Date(timeIntervalSince1970: 10000), "with the held reset time")
        Harness.equal(updated?.window(.fiveHour)?.observedAt, Date(timeIntervalSince1970: 5000), "observed when the app sampled it")
        Harness.equal(updated?.observedAt, Date(timeIntervalSince1970: 6000), "the snapshot's own time does not go back")
    }

    static func ignoresSamplesOutsideTheHeldInstance() {
        // The held instance runs from 10000 − 5h = −8000 to 10000.
        let snap = held(fiveHour: 10, observedAt: 3000, statuslineAt: 3000)
        Harness.check(snap.applying(sample(at: 10500, fiveHour: 3)) == nil, "a sample after the reset belongs to an unknown instance")
    }

    static func ignoresSamplesOlderThanTheHeldReading() {
        let snap = held(fiveHour: 30, observedAt: 3000, statuslineAt: 3000)
        Harness.check(snap.applying(sample(at: 2000, fiveHour: 12)) == nil, "an older sample changes nothing")
    }

    static func aDesktopDropIsACredit() {
        let snap = held(fiveHour: 60, observedAt: 3000, statuslineAt: 3000)
        let updated = snap.applying(sample(at: 4000, fiveHour: 0))
        Harness.equal(updated?.window(.fiveHour)?.usedPercent, 0, "a live server reading may show a credit")
        Harness.equal(updated?.window(.fiveHour)?.creditAt, Date(timeIntervalSince1970: 4000), "and it is recorded")
    }

    static func cannotStartAWindowOnItsOwn() {
        let empty = UsageSnapshot(source: .statusline, observedAt: Date(timeIntervalSince1970: 0), windows: [])
        Harness.check(empty.applying(sample(at: 4000, fiveHour: 20)) == nil, "without a held window there is no reset time")
    }
}
