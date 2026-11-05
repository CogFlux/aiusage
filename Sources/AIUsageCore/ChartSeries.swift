import Foundation

/// Inspect the same straight or stepped segments that the chart draws, without extrapolating.
public struct ChartSeries {
    public struct Point: Equatable {
        public var at: Date
        public var value: Double

        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    public enum Interpolation { case linear, stepEnd }

    public struct Sample: Equatable {
        public var point: Point
        public var isRecorded: Bool
    }

    /// Points must be ordered by time. Only exact endpoints are marked as recorded.
    public static func sample(at date: Date, points: [Point], interpolation: Interpolation = .linear) -> Sample? {
        guard let first = points.first, let last = points.last,
              date >= first.at, date <= last.at else { return nil }
        guard let upper = points.firstIndex(where: { $0.at >= date }) else { return nil }
        let right = points[upper]
        if right.at == date { return Sample(point: right, isRecorded: true) }
        guard upper > 0 else { return nil }
        let left = points[upper - 1]
        let fraction = date.timeIntervalSince(left.at) / right.at.timeIntervalSince(left.at)
        let value: Double
        switch interpolation {
        case .linear: value = left.value + (right.value - left.value) * fraction
        case .stepEnd: value = left.value
        }
        return Sample(point: Point(at: date, value: value), isRecorded: false)
    }
}
