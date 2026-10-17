import AIUsageCore
import Charts
import SwiftUI

/// The header button that opens and closes a block's chart.
struct ChartToggle: View {
    let provider: Provider
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let shown = store.chartProviders.contains(provider)
        Button {
            store.toggleChart(provider)
        } label: {
            Image(systemName: "chart.xyaxis.line")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(shown ? Color.accentColor : Color.primary)
        .help(store.strings.chartToggle)
    }
}

/// Which window the chart shows. An object rather than `@State`, which is a macro the Command Line
/// Tools cannot expand.
final class ChartSelection: ObservableObject {
    @Published var kind: WindowKind?
    /// `UsageHistory.Instance.id`; nil follows the current window.
    @Published var instanceID: String?
}

/// Used percentage over one window instance, from its start to its reset, against the even-pace
/// line the pace numbers use. Pages back through the instances the history still holds.
struct UsageChart: View {
    let kinds: [WindowKind]
    @ObservedObject var history: HistoryStore
    /// The window the provider reports now, per kind.
    let current: (WindowKind) -> UsageWindow?
    /// The pace origin in effect for the current window, per kind.
    let checkpoint: (WindowKind) -> PaceCheckpoint?
    let now: Date
    @EnvironmentObject var store: UsageStore
    @StateObject private var selection = ChartSelection()

    private var s: Strings { store.strings }

    private var kind: WindowKind {
        if let chosen = selection.kind, kinds.contains(chosen) { return chosen }
        return kinds.contains(store.menuBarKind) ? store.menuBarKind : kinds[0]
    }

    /// The recorded instances of the kind, plus the current window when nothing is recorded for it yet.
    private var instances: [UsageHistory.Instance] {
        var list = history.history.instances(of: kind)
        if let live = current(kind), history.history.instance(matching: live) == nil {
            list.append(UsageHistory.Instance(kind: kind, resetsAt: live.resetsAt, points: []))
        }
        return list
    }

    private var shownIndex: Int? {
        let list = instances
        guard !list.isEmpty else { return nil }
        if let id = selection.instanceID, let index = list.firstIndex(where: { $0.id == id }) { return index }
        if let live = current(kind), let index = list.lastIndex(where: {
            abs($0.resetsAt.timeIntervalSince(live.resetsAt)) <= UsageHistory.sameInstanceTolerance
        }) {
            return index
        }
        return list.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if let index = shownIndex {
                let instance = instances[index]
                if instance.points.isEmpty {
                    empty
                } else {
                    chart(instance)
                    legend(instance)
                }
            } else {
                empty
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if kinds.count > 1 {
                Picker("", selection: Binding(get: { kind }, set: {
                    selection.kind = $0
                    selection.instanceID = nil
                })) {
                    ForEach(kinds, id: \.self) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 4)
            let list = instances
            let index = shownIndex
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled((index ?? 0) <= 0)
                .help(s.chartEarlier)
            if let index {
                Text(rangeLabel(list[index]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(index.map { $0 >= list.count - 1 } ?? true)
                .help(s.chartLater)
        }
    }

    private func step(_ offset: Int) {
        let list = instances
        guard let index = shownIndex, list.indices.contains(index + offset) else { return }
        let target = list[index + offset]
        // Back on the current window, follow it again so the chart moves on with the next reset.
        let isLive = current(kind).map { abs($0.resetsAt.timeIntervalSince(target.resetsAt)) <= UsageHistory.sameInstanceTolerance } ?? false
        selection.instanceID = isLive ? nil : target.id
    }

    private var empty: some View {
        Text(s.chartEmpty)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private func isLive(_ instance: UsageHistory.Instance) -> Bool {
        now < instance.resetsAt && now >= instance.startsAt
    }

    private func chart(_ instance: UsageHistory.Instance) -> some View {
        let start = instance.startsAt
        let segments = UsageHistory.segments(instance)
        let target = PaceConfig().targetPercent
        let live = isLive(instance)
        // A re-pace or credit origin is known only for the window being reported now.
        let origin = live ? checkpoint(instance.kind).flatMap { cp in
            cp.at >= start && cp.at < instance.resetsAt ? cp : nil
        } : nil
        return Chart {
            LineMark(x: .value("Time", start), y: .value("Percent", 0), series: .value("Line", "pace"))
                .foregroundStyle(Color.secondary.opacity(origin == nil ? 0.7 : 0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            LineMark(x: .value("Time", instance.resetsAt), y: .value("Percent", target), series: .value("Line", "pace"))
                .foregroundStyle(Color.secondary.opacity(origin == nil ? 0.7 : 0.3))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let origin {
                LineMark(x: .value("Time", origin.at), y: .value("Percent", origin.usedPercent), series: .value("Line", "repace"))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                LineMark(x: .value("Time", instance.resetsAt), y: .value("Percent", target), series: .value("Line", "repace"))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
                if segment.measured, segment.points.count == 1, let point = segment.points.first {
                    PointMark(x: .value("Time", point.at), y: .value("Percent", point.usedPercent))
                        .symbolSize(12)
                        .foregroundStyle(Color.accentColor)
                } else {
                    ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.at), y: .value("Percent", point.usedPercent),
                                 series: .value("Line", "used\(offset)"))
                            .foregroundStyle(segment.measured ? Color.accentColor : Color.secondary.opacity(0.6))
                            .lineStyle(segment.measured
                                ? StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                                : StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
                    }
                }
            }
            if live {
                RuleMark(x: .value("Time", now))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: start...instance.resetsAt)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(axisLabel(date, kind: instance.kind)) }
                }
            }
        }
        .font(.caption2)
        .frame(height: 130)
    }

    private func legend(_ instance: UsageHistory.Instance) -> some View {
        let hasGap = UsageHistory.segments(instance).contains { !$0.measured }
        return HStack(spacing: 12) {
            swatch(Color.accentColor, StrokeStyle(lineWidth: 2), s.used)
            swatch(Color.secondary.opacity(0.7), StrokeStyle(lineWidth: 1, dash: [3, 3]), s.budget)
            if hasGap {
                swatch(Color.secondary.opacity(0.6), StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]), s.chartGap)
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ style: StrokeStyle, _ label: String) -> some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 14, y: 4))
            }
            .stroke(color, style: style)
            .frame(width: 14, height: 8)
            Text(label)
        }
    }

    /// "13:00–18:00" for a 5-hour window, "Oct 12 – Oct 19" for the longer ones; a 5-hour window
    /// not from today names its day.
    private func rangeLabel(_ instance: UsageHistory.Instance) -> String {
        let locale = store.locale
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let start = instance.startsAt
        if instance.kind == .fiveHour {
            let range = start.formatted(time) + "–" + instance.resetsAt.formatted(time)
            return Calendar.current.isDate(start, inSameDayAs: now) ? range : start.formatted(day) + " " + range
        }
        return start.formatted(day) + " – " + instance.resetsAt.formatted(day)
    }

    private func axisLabel(_ date: Date, kind: WindowKind) -> String {
        let locale = store.locale
        switch kind {
        case .fiveHour: return date.formatted(Date.FormatStyle.dateTime.hour().minute().locale(locale))
        case .sevenDay: return date.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale))
        case .month: return date.formatted(Date.FormatStyle.dateTime.month(.defaultDigits).day().locale(locale))
        }
    }
}

/// DeepSeek has no windows: its chart is the balance over the last 30 days, from the ledger's
/// change points, each held until the next.
struct BalanceChart: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore

    static let span: TimeInterval = 30 * 86400

    private struct Step: Identifiable {
        var at: Date
        var balance: Double
        var id: Date { at }
    }

    private var steps: [Step] {
        let from = deepseek.now.addingTimeInterval(-Self.span)
        let samples = deepseek.ledger.samples
        // The last change before the range sets the level the range opens at.
        let opening = samples.last { $0.at < from }.map { Step(at: from, balance: $0.balance) }
        var steps = (opening.map { [$0] } ?? []) + samples.filter { $0.at >= from }.map { Step(at: $0.at, balance: $0.balance) }
        if let last = steps.last, let seen = deepseek.ledger.lastObservedAt, seen > last.at {
            steps.append(Step(at: seen, balance: last.balance))
        }
        return steps
    }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 6) {
            if steps.count < 2 {
                Text(store.strings.chartEmpty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                Chart(steps) { step in
                    LineMark(x: .value("Time", step.at), y: .value("Balance", step.balance))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(deepseek.money(amount, compact: true)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(Date.FormatStyle.dateTime.month(.defaultDigits).day().locale(store.locale)))
                            }
                        }
                    }
                }
                .font(.caption2)
                .frame(height: 130)
                Text(store.strings.deepseekBalance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
