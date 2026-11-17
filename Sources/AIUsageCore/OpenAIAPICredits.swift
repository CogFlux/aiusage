import Foundation

public enum OpenAIAPICredits {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// A current Pro subscription gives the billing timestamps directly. If only
    /// its end is available, use one month of costs leading up to that timestamp. Codex
    /// sometimes retains the old claims just after a renewal, so estimate one additional cycle.
    public static func subscriptionCycle(containing date: Date, subscription: CodexSubscription?) -> DateInterval? {
        guard let subscription, CodexSubscription.isProPlan(subscription.plan),
              let end = subscription.activeUntil else { return nil }
        if date >= end {
            // An observed Jan 31 → Feb 28 cycle points to a Mar 31 anniversary.
            let nextEnd: Date?
            if let start = subscription.activeStart,
               utcCalendar.date(byAdding: .month, value: 1, to: start) == end {
                nextEnd = utcCalendar.date(byAdding: .month, value: 2, to: start)
            } else {
                nextEnd = utcCalendar.date(byAdding: .month, value: 1, to: end)
            }
            guard let nextEnd, date < nextEnd else { return nil }
            return DateInterval(start: end, end: nextEnd)
        }
        guard let previousMonth = utcCalendar.date(byAdding: .month, value: -1, to: end) else { return nil }
        let start: Date
        if let activeStart = subscription.activeStart, end.timeIntervalSince(activeStart) <= 32 * 86_400 {
            start = activeStart
        } else {
            start = previousMonth
        }
        guard start <= date else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func pace(for window: UsageWindow, cycle: DateInterval, now: Date,
                            checkpoint: PaceCheckpoint?) -> Pace {
        var budget = PaceWindow.rateLimit(window, provider: "openai-api", checkpoint: checkpoint)
        // Use the subscription's real start, including months with a shortened billing period.
        budget.startsAt = cycle.start
        return PaceCalculator.compute(budget, now: now)
    }

    public struct CostsPage: Decodable {
        private struct Bucket: Decodable {
            struct Result: Decodable {
                struct Amount: Decodable {
                    let value: Decimal
                    let currency: String
                }

                let amount: Amount
            }

            let results: [Result]
        }

        public let spend: Decimal
        public let nextPage: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let buckets = try container.decode([Bucket].self, forKey: .data)
            var spend: Decimal = 0
            for amount in buckets.flatMap({ $0.results.map(\.amount) }) {
                guard amount.currency.lowercased() == "usd" else {
                    throw DecodingError.dataCorruptedError(forKey: .data, in: container,
                                                           debugDescription: "Expected costs in USD")
                }
                spend += amount.value
            }
            self.spend = spend
            if try container.decode(Bool.self, forKey: .hasMore) {
                let cursor = try container.decode(String.self, forKey: .nextPage)
                guard !cursor.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .nextPage, in: container,
                                                           debugDescription: "Empty costs page cursor")
                }
                nextPage = cursor
            } else {
                nextPage = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case data
            case nextPage = "next_page"
            case hasMore = "has_more"
        }
    }
}
