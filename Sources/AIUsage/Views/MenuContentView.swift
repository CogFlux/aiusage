import AIUsageCore
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !store.claudeCodeInstalled {
                claudeCodeMissing
            } else if store.fileHasNoQuota, store.snapshot == nil {
                caption(s.noQuotaInData)
            }
            Divider()
            ForEach(WindowKind.allCases, id: \.self) { kind in
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
                                      start: { store.repaceFromNow(kind) },
                                      clear: { store.clearCheckpoint(kind) })
                              : nil)
            }
            Divider()
            probeSection
            if deepseek.enabled {
                ProviderDivider()
                DeepSeekSection()
            }
            if !store.hookInstalled, store.claudeCodeInstalled {
                Divider()
                hookPrompt
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { deepseek.tick() }
    }

    private var header: some View {
        HStack {
            Text("Claude").font(.title3.bold())
            Spacer()
            if let snap = store.snapshot, let age = store.snapshotAge {
                Text(sourceLabel(snap.source) + " · " + age)
                    .font(.caption)
                    .foregroundStyle(store.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
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
        }
    }

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    store.probe()
                } label: {
                    Label(s.probeNow, systemImage: "arrow.clockwise")
                }
                .disabled(store.probeState == .running)
                if store.probeState == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            caption(s.probeHint)
            if case let .failed(message) = store.probeState {
                errorText(message)
            }
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
            SettingsLink {
                Label(s.settings, systemImage: "gearshape")
            }
            .simultaneousGesture(TapGesture().onEnded {
                // Accessory apps open Settings behind other windows unless activated.
                NSApplication.shared.activate(ignoringOtherApps: true)
            })
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
                        baselineBudget: pace.baselineBudgetPercent, checkpoint: pace.checkpoint?.usedPercent)
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
                Text(strings.windowIdle).font(.caption).foregroundStyle(.secondary)
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
    @ViewBuilder
    private func repaceRow(pace: Pace, actions: RepaceActions) -> some View {
        if let checkpoint = pace.checkpoint {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered").font(.caption).foregroundStyle(.secondary)
                Text(strings.repacedSince(UsageFormatter.percent(PaceConfig().targetPercent - checkpoint.usedPercent), clock(checkpoint.at)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
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

/// Boundary between providers: heavier and more spaced than the thin dividers used inside one
/// provider's block, so the two levels of grouping read differently.
struct ProviderDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(height: 2)
            .padding(.vertical, 6)
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
