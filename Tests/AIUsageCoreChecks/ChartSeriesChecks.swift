import AIUsageCore
import Foundation

enum ChartSeriesChecks {
    static func run() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [ChartSeries.Point(at: start, value: 12.5),
                      ChartSeries.Point(at: start.addingTimeInterval(100), value: 37.5)]
        let middle = start.addingTimeInterval(40)
        let sample = ChartSeries.sample(at: middle, points: points)
        Harness.equal(sample?.point.at, middle, "inspection keeps the clicked time")
        Harness.equal(sample?.point.value, 22.5, "linear inspection interpolates usage")
        Harness.equal(sample?.isRecorded, false, "interpolation is not an observation")
        Harness.equal(ChartSeries.sample(at: start, points: points)?.isRecorded, true, "first endpoint recorded")
        Harness.equal(ChartSeries.sample(at: points[1].at, points: points)?.point.value, 37.5, "last endpoint exact")
        Harness.equal(ChartSeries.sample(at: middle, points: points, interpolation: .stepEnd)?.point.value,
                      12.5, "balance holds the earlier value between changes")
        Harness.equal(ChartSeries.sample(at: start.addingTimeInterval(-1), points: points), nil, "no backward extrapolation")
        Harness.equal(ChartSeries.sample(at: start.addingTimeInterval(101), points: points), nil, "no forward extrapolation")
        Harness.equal(ChartSeries.sample(at: start, points: []), nil, "empty line has no values")
        Harness.equal(ChartSeries.sample(at: start, points: [points[0]])?.point.value, 12.5, "isolated point selectable")
        Harness.equal(ChartSeries.sample(at: middle, points: [points[0]]), nil, "isolated point has no invented line")
        for plan in ["pro", "prolite", " ProLite ", "PRO", "pro_5x", "pro-20x"] {
            Harness.check(CodexSubscription.isProPlan(plan), "Pro variant recognized: \(plan)")
        }
        for plan in [nil, "", "unknown", "plus", "team", "enterprise"] as [String?] {
            Harness.check(!CodexSubscription.isProPlan(plan), "non-Pro plan keeps both windows")
        }
    }
}
