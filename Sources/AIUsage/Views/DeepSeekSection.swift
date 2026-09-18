import AIUsageCore
import SwiftUI

/// DeepSeek block in the popover: balance and burn rate, plus the monthly budget pace when set.
struct DeepSeekSection: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("DeepSeek").font(.title3.bold())
                Spacer()
                if deepseek.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let observed = deepseek.ledger.lastObservedAt {
                    Text(age(observed)).font(.caption).foregroundStyle(.secondary)
                }
                // Free (no tokens), so a plain icon rather than Claude's button-with-cost-hint.
                Button {
                    deepseek.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(s.deepseekRefresh)
                .disabled(!deepseek.hasAPIKey || deepseek.isRefreshing)
            }

            if !deepseek.hasAPIKey {
                Text(s.deepseekNoKey).font(.caption).foregroundStyle(.secondary)
            } else if let latest = deepseek.latest {
                HStack(spacing: 14) {
                    stat(s.deepseekBalance, deepseek.money(latest.total))
                    stat(s.deepseekToday, deepseek.money(deepseek.spentToday))
                    stat(s.deepseekThisMonth, deepseek.money(deepseek.spentThisMonth))
                    if let rate = deepseek.burnRate {
                        stat(s.deepseekPerDayBasis(spanLabel(rate.span)), deepseek.money(rate.perDay))
                    }
                    if let runout = deepseek.runoutDate {
                        stat(s.deepseekRunsOut, runout.formatted(Date.FormatStyle.dateTime.month(.abbreviated).day().locale(store.locale)))
                    }
                }
                if deepseek.burnRatePerDay == nil {
                    Text(s.deepseekGathering).font(.caption).foregroundStyle(.secondary)
                }
                if let pace = deepseek.budgetPace {
                    budget(pace)
                }
            } else if let error = deepseek.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func budget(_ pace: Pace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.deepseekBudgetTitle).font(.headline)
                Spacer()
                Text(s.resetsLine(deepseek.monthInterval.end.formatted(Date.FormatStyle.dateTime.month(.abbreviated).day().locale(store.locale)),
                                  UsageFormatter.countdown(to: deepseek.monthInterval.end, from: deepseek.now)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            PaceBar(used: pace.usedPercent, budget: pace.budgetPercent, status: pace.status)
            HStack(spacing: 14) {
                stat(s.deepseekSpent, UsageFormatter.percent(pace.usedPercent))
                stat(s.budget, UsageFormatter.percent(pace.budgetPercent))
                stat(s.delta, UsageFormatter.signed(pace.deltaPercent),
                     color: pace.status == .overPace ? .red : pace.status == .underPace ? .green : .primary)
                if let projected = pace.projectedPercent {
                    stat(s.projected, UsageFormatter.percent(projected))
                }
            }
        }
        .padding(.top, 4)
    }

    /// "6h" while the ledger is young, "7d" once the full window is covered.
    private func spanLabel(_ span: TimeInterval) -> String {
        span >= 86400 ? "\(Int((span / 86400).rounded()))d" : "\(max(1, Int((span / 3600).rounded())))h"
    }

    private func age(_ date: Date) -> String {
        if deepseek.now.timeIntervalSince(date) < 60 { return s.justNow }
        let f = RelativeDateTimeFormatter()
        f.locale = store.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: deepseek.now)
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary).fixedSize()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(color).fixedSize()
        }
    }
}
