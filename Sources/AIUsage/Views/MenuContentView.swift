import AIUsageCore
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore
    @EnvironmentObject var codex: CodexStore
    @EnvironmentObject var opencodeGo: OpenCodeGoStore
    @Environment(\.dismiss) private var dismiss
    /// An object rather than `@State`, which is a macro the Command Line Tools cannot expand.
    @StateObject private var providerBlocksHeight = MeasuredHeight()

    private var s: Strings { store.strings }

    private var panelProviders: [Provider] {
        var enabled: Set<Provider> = store.enabled ? [.claude] : []
        if codex.enabled { enabled.insert(.codex) }
        if deepseek.enabled { enabled.insert(.deepseek) }
        if opencodeGo.enabled { enabled.insert(.opencodego) }
        return store.layout.panel(enabled: enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let providers = panelProviders
            if providers.count > 1 {
                ProviderSwitcher(providers: providers, selected: selectedProvider(among: providers))
                Divider()
            }
            // A block can still be taller than the screen (Claude with its hook prompt on a small
            // display). It scrolls then, and the footer stays in view; until then the scroll view
            // is exactly the block's height.
            ScrollView(.vertical) {
                providerBlocks
                    .padding(.trailing, providerBlocksHeight.value > maxProviderBlocksHeight ? 10 : 0)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ProviderBlocksHeight.self, value: geo.size.height)
                    })
            }
            .frame(height: min(providerBlocksHeight.value, maxProviderBlocksHeight))
            .onPreferenceChange(ProviderBlocksHeight.self) { providerBlocksHeight.value = $0 }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(PanelTopPin())
        .onAppear {
            store.menuOpened()
            deepseek.tick()
            codex.tick()
            opencodeGo.tick()
            // Picks up a `claude` installed since the last look.
            if store.resolvedClaudePath == nil { store.refreshClaudePath() }
        }
    }

    /// The saved choice while it is shown, else the first provider in the layout's order.
    private func selectedProvider(among providers: [Provider]) -> Provider {
        store.panelSelection.flatMap { providers.contains($0) ? $0 : nil } ?? providers[0]
    }

    /// The selected provider's block; with only one provider shown there is no switcher, just it.
    @ViewBuilder
    private var providerBlocks: some View {
        let providers = panelProviders
        if providers.isEmpty {
            caption(s.panelEmpty)
        } else {
            switch selectedProvider(among: providers) {
            case .claude: claudeSection
            case .codex: CodexSection()
            case .deepseek: DeepSeekSection()
            case .opencodego: OpenCodeGoSection()
            }
        }
    }

    /// The screen's height below the menu bar and above the Dock, less the footer, the padding and a
    /// margin, so the whole panel always fits.
    private var maxProviderBlocksHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 110)
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if case let .failed(message) = store.probeState {
                errorText(message)
            }
            if !store.claudeCodeInstalled {
                claudeCodeMissing
            } else if store.fileHasNoQuota, store.snapshot == nil {
                caption(s.noQuotaInData)
            }
            if store.chartProviders.contains(.claude) {
                UsageChart(kinds: WindowKind.claudeKinds, history: store.history,
                           current: { store.snapshot?.window($0) },
                           checkpoint: { store.pace(for: $0)?.checkpoint },
                           now: store.now)
            }
            Divider()
            ForEach(WindowKind.claudeKinds, id: \.self) { kind in
                WindowRow(kind: kind,
                          window: store.snapshot?.window(kind),
                          pace: store.pace(for: kind),
                          idle: store.isIdle(kind),
                          now: store.now,
                          strings: s,
                          locale: store.locale,
                          // Re-pacing is offered on the 7-day window only: that is where an early
                          // overspend haunts you for days. The 5-hour window is over soon anyway.
                          repace: kind == .sevenDay
                              ? .init(available: store.canRepace(kind),
                                      automatic: store.checkpointIsAutomatic(kind),
                                      start: { store.repaceFromNow(kind) },
                                      clear: { store.clearCheckpoint(kind) })
                              : nil)
            }
            if !store.hookInstalled, store.claudeCodeInstalled {
                Divider()
                hookPrompt
            }
        }
    }

    /// Same shape as the Codex and DeepSeek headers. Their refresh is free; this one sends a tiny
    /// request, so the tooltip says what it costs.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude").font(.title3.bold())
            Spacer()
            if store.probeState == .running {
                ProgressView().controlSize(.small)
            } else if let confirmed = store.confirmed, let age = store.snapshotAge {
                Text(sourceLabel(confirmed.source) + " · " + age)
                    .font(.caption)
                    .foregroundStyle(store.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
            ChartToggle(provider: .claude)
            Button {
                store.probe()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(s.probeNow + " — " + (store.oauthQueryEnabled ? s.oauthRefreshHint : s.probeHint))
            .disabled(store.probeState == .running)
        }
    }

    private var claudeCodeMissing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(s.claudeCodeMissingTitle).font(.headline)
            }
            caption(s.claudeCodeMissingBody)
            Button(s.installClaudeCode) {
                NSWorkspace.shared.open(UsageStore.claudeCodeInstallURL)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceLabel(_ source: SnapshotSource) -> String {
        switch source {
        case .statusline: return s.sourceStatusline
        case .probe: return s.sourceProbe
        case .oauth: return s.sourceOAuth
        }
    }

    /// First-run nudge; once the hook is installed this moves into Settings → Claude Code.
    private var hookPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(s.hookNotInstalled)
                Spacer()
                Button(s.install) {
                    store.installHook()
                }
            }
            caption(s.hookHint)
            if let error = store.hookError {
                errorText(error)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                // Opening a window of this same app does not dismiss the panel, and closing it
                // behind SwiftUI's back leaves it believing the panel is still up. The dismissal
                // lands on whatever is key when it runs, so open Settings only once it is done.
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SettingsPresenter.open() }
            } label: {
                Label(s.settings, systemImage: "gearshape")
            }
            Spacer()
            Button(s.quit) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WindowRow: View {
    struct RepaceActions {
        var available: Bool
        /// The origin was placed by a quota credit, not by the user.
        var automatic: Bool
        var start: () -> Void
        var clear: () -> Void
    }

    let kind: WindowKind
    let window: UsageWindow?
    let pace: Pace?
    let idle: Bool
    let now: Date
    let strings: Strings
    let locale: Locale
    var repace: RepaceActions? = nil
    /// What to say when the provider reports no such window; Claude's text by default.
    var idleText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strings.windowTitle(kind)).font(.headline)
                Spacer()
                if let window {
                    Text(strings.resetsLine(clock(window.resetsAt),
                                            UsageFormatter.countdown(to: window.resetsAt, from: now)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let pace {
                PaceBar(used: pace.usedPercent, budget: pace.budgetPercent, status: pace.status,
                        baselineBudget: userRepaced(pace) ? pace.baselineBudgetPercent : nil,
                        checkpoint: userRepaced(pace) ? pace.checkpoint?.usedPercent : nil)
                HStack(spacing: 14) {
                    stat(strings.used, UsageFormatter.percent(pace.usedPercent))
                    stat(strings.budget, UsageFormatter.percent(pace.budgetPercent))
                    stat(strings.delta, UsageFormatter.signed(pace.deltaPercent), color: deltaColor(pace.status))
                    // Always render both so the row keeps its shape; "—" means too early to
                    // project, or (for run-out) the window will not hit the target before reset.
                    if let projected = pace.projectedPercent {
                        stat(strings.projected, UsageFormatter.percent(projected))
                    } else {
                        stat(strings.projected, "—", color: .secondary)
                    }
                    if let runout = pace.runoutAt {
                        stat(strings.runout, runout <= now ? strings.exhausted : clock(runout))
                    } else {
                        stat(strings.runout, "—", color: .secondary)
                    }
                }
                if pace.status == .tooEarly, let from = pace.projectionAvailableAt {
                    note(strings.tooEarlyNote(clock(from)))
                } else if pace.status == .reset {
                    note(strings.resetNote)
                }
                if let repace, pace.status != .reset {
                    repaceRow(pace: pace, actions: repace)
                }
            } else if idle {
                Text(idleText ?? strings.windowIdle).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(strings.noData).foregroundStyle(.secondary)
            }
        }
    }

    /// Time of day alone when the date is today; otherwise prefix month and day, since the
    /// 7-day window's reset and run-out times are usually days away.
    private func clock(_ date: Date) -> String {
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(time)
        }
        return date.formatted(time.month(.abbreviated).day())
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(color)
        }
    }

    /// Either the offer to re-pace, or — once a checkpoint is set — what it is pacing and a way out.
    /// A quota credit rebases the budget line on its own; only a re-pace the user asked for gets
    /// the caption, the Clear button and the extra ticks explaining it.
    private func userRepaced(_ pace: Pace) -> Bool {
        pace.checkpoint != nil && !(repace?.automatic ?? false)
    }

    @ViewBuilder
    private func repaceRow(pace: Pace, actions: RepaceActions) -> some View {
        if let checkpoint = pace.checkpoint, userRepaced(pace) {
            HStack(spacing: 8) {
                Text(repaceCaption(pace: pace, checkpoint: checkpoint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(strings.repaceClear, action: actions.clear)
                    .controlSize(.small)
            }
        } else if actions.available {
            HStack {
                Button(strings.repaceFromNow, action: actions.start)
                    .controlSize(.small)
                    .help(strings.repaceHelp)
                Spacer()
            }
        }
    }

    private func repaceCaption(pace: Pace, checkpoint: PaceCheckpoint) -> String {
        let config = PaceConfig()
        // "1d 3h ago" stays short whatever the locale's date format does once a day has passed.
        var caption = strings.repacedSince(UsageFormatter.percent(config.targetPercent - checkpoint.usedPercent),
                                           UsageFormatter.countdown(to: now, from: checkpoint.at))
        // The original line is still on the bar as the faint tick; spell out its delta too, so a
        // glance at "the whole week" needs no mode switch.
        if let baseline = pace.baselineBudgetPercent {
            let overall = UsageFormatter.marker(delta: pace.usedPercent - baseline,
                                                tolerance: config.tolerance(for: kind))
            caption += " · " + strings.repaceOverall(overall)
        }
        return caption
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func deltaColor(_ status: PaceStatus) -> Color {
        switch status {
        case .overPace: return .red
        case .underPace: return .green
        case .onTrack, .tooEarly, .reset: return .primary
        }
    }
}

/// Used fill plus a tick at the even-pace budget so the gap is visible at a glance.
/// With a checkpoint, two more ticks: a faint one where the original budget line would be, and
/// a dashed one at the checkpoint the re-paced budget now grows from.
struct PaceBar: View {
    let used: Double
    let budget: Double
    let status: PaceStatus
    var baselineBudget: Double? = nil
    var checkpoint: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(fillColor)
                    .frame(width: fraction(used) * width)
                if let baselineBudget {
                    tick(at: baselineBudget, width: width, opacity: 0.25)
                }
                if let checkpoint {
                    tick(at: checkpoint, width: width, opacity: 0.55, dashed: true)
                }
                tick(at: budget, width: width, opacity: 0.85)
            }
        }
        .frame(height: 8)
    }

    private func tick(at percent: Double, width: CGFloat, opacity: Double, dashed: Bool = false) -> some View {
        Group {
            if dashed {
                Path { path in
                    path.move(to: CGPoint(x: 1, y: 0))
                    path.addLine(to: CGPoint(x: 1, y: 8))
                }
                .stroke(Color.primary.opacity(opacity), style: StrokeStyle(lineWidth: 2, dash: [2, 1.5]))
                .frame(width: 2)
            } else {
                Rectangle().fill(Color.primary.opacity(opacity)).frame(width: 2)
            }
        }
        .offset(x: max(0, fraction(percent) * width - 1))
    }

    private func fraction(_ percent: Double) -> CGFloat {
        CGFloat(max(0, min(1, percent / 100)))
    }

    private var fillColor: Color {
        switch status {
        case .overPace: return .red
        case .underPace: return .green
        case .onTrack, .tooEarly: return .accentColor
        case .reset: return .gray
        }
    }
}

/// The provider blocks' natural height, as laid out inside the scroll view.
private struct ProviderBlocksHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

final class MeasuredHeight: ObservableObject {
    @Published var value: CGFloat = 0
}
