import AIUsageCore
import SwiftUI

/// Google AI block in the popover: Antigravity (local language server / `agy` CLI) and, optionally,
/// Gemini web/app (`gemini.google.com/usage`). Either or both can be enabled in Settings → Google AI.
struct GoogleAISection: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var antigravity: AntigravityStore
    @EnvironmentObject var geminiApp: GeminiAppStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if antigravity.enabled { antigravityBlock }
            if antigravity.enabled && geminiApp.enabled { Divider() }
            if geminiApp.enabled { geminiAppBlock }
        }
    }

    // MARK: - Antigravity

    private var antigravityBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            antigravityHeader
            if let error = antigravity.lastError {
                Text(error).font(.caption).foregroundStyle(antigravity.errorIsMinor ? Color.secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = antigravity.usage {
                if let prompt = usage.availablePromptCredits {
                    let flow = usage.availableFlowCredits.map(formatCredits)
                    Text(s.antigravityCreditsLine(formatCredits(prompt), flow))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                let repKinds = usage.representativeWindows.map(\.kind)
                if !repKinds.isEmpty, store.chartProviders.contains(.googleAI) {
                    UsageChart(kinds: repKinds, history: antigravity.history,
                               current: { antigravity.usage?.representativeWindow($0) },
                               checkpoint: { antigravity.representativeCheckpoint(for: $0) },
                               now: antigravity.now)
                }
                ForEach(usage.groups) { group in
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if !group.windows.isEmpty {
                            ForEach(group.windows, id: \.kind) { window in
                                WindowRow(kind: window.kind,
                                          window: window,
                                          pace: antigravity.pace(forGroup: group.id, kind: window.kind),
                                          idle: false,
                                          now: antigravity.now,
                                          strings: s,
                                          locale: store.locale,
                                          repace: window.kind == .sevenDay
                                              ? .init(available: antigravity.canRepace(groupID: group.id, kind: window.kind),
                                                      automatic: antigravity.checkpointIsAutomatic(groupID: group.id, kind: window.kind),
                                                      start: { antigravity.repaceFromNow(groupID: group.id, kind: window.kind) },
                                                      clear: { antigravity.clearCheckpoint(groupID: group.id, kind: window.kind) })
                                              : nil)
                            }
                        } else if let used = group.fallbackUsedPercent {
                            FallbackQuotaRow(usedPercent: used,
                                             resetsAt: group.fallbackResetsAt,
                                             description: group.fallbackDescription,
                                             now: antigravity.now,
                                             strings: s,
                                             locale: store.locale)
                        }
                    }
                }
            }
        }
    }

    private var antigravityHeader: some View {
        HStack(spacing: 8) {
            Text("Antigravity").font(.title3.bold())
            if let plan = antigravity.usage?.planName {
                planBadge(plan)
            }
            if antigravity.usage?.limitReached == true {
                Text(s.codexLimitReached).font(.caption.bold()).foregroundStyle(.red)
            }
            Spacer()
            if antigravity.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let usage = antigravity.usage {
                Text(sourceLabel(usage.source) + " · " + store.readingAge(usage.observedAt, relativeTo: antigravity.now))
                    .font(.caption)
                    .foregroundStyle(antigravity.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
            if antigravity.usage?.representativeWindows.isEmpty == false {
                ChartToggle(provider: .googleAI)
            }
            Button {
                antigravity.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(s.codexRefresh)
            .disabled(antigravity.isRefreshing)
        }
    }

    private func sourceLabel(_ source: AntigravitySource) -> String {
        switch source {
        case .app: return s.antigravitySourceApp
        case .cli: return s.antigravitySourceCLI
        case .ide: return s.antigravitySourceIDE
        }
    }

    private func formatCredits(_ value: Double) -> String {
        if value.rounded() == value {
            return Int(value).formatted(.number.locale(store.locale))
        }
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(store.locale))
    }

    // MARK: - Gemini app (gemini.google.com)

    private var geminiAppBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            geminiAppHeader
            if let error = geminiApp.lastError {
                Text(error).font(.caption).foregroundStyle(geminiApp.errorIsMinor ? Color.secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !geminiApp.hasCookie {
                Text(s.geminiAppNoCookie).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !antigravity.enabled, store.chartProviders.contains(.googleAI) {
                UsageChart(kinds: WindowKind.claudeKinds, history: geminiApp.history,
                           current: { geminiApp.usage?.window($0) },
                           checkpoint: { geminiApp.pace(for: $0)?.checkpoint },
                           now: geminiApp.now)
            }
            if geminiApp.usage != nil {
                Divider()
                ForEach(WindowKind.claudeKinds, id: \.self) { kind in
                    WindowRow(kind: kind,
                              window: geminiApp.usage?.window(kind),
                              pace: geminiApp.pace(for: kind),
                              idle: geminiApp.isIdle(kind),
                              now: geminiApp.now,
                              strings: s,
                              locale: store.locale,
                              repace: kind == .sevenDay
                                  ? .init(available: geminiApp.canRepace(kind),
                                          automatic: geminiApp.checkpointIsAutomatic(kind),
                                          start: { geminiApp.repaceFromNow(kind) },
                                          clear: { geminiApp.clearCheckpoint(kind) })
                                  : nil,
                              idleText: s.geminiAppWindowIdle)
                }
            }
        }
    }

    private var geminiAppHeader: some View {
        HStack(spacing: 8) {
            Text("Gemini").font(.title3.bold())
            if let plan = geminiApp.usage?.planLabel {
                planBadge(plan)
            }
            if geminiApp.usage?.limitReached == true {
                Text(s.codexLimitReached).font(.caption.bold()).foregroundStyle(.red)
            }
            Spacer()
            if geminiApp.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let observed = geminiApp.usage?.observedAt {
                Text(store.readingAge(observed, relativeTo: geminiApp.now)).font(.caption)
                    .foregroundStyle(geminiApp.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
            if !antigravity.enabled {
                ChartToggle(provider: .googleAI)
            }
            Button {
                geminiApp.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(s.codexRefresh)
            .disabled(geminiApp.isRefreshing || !geminiApp.canRefresh)
        }
    }

    private func planBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .lineLimit(1)
    }
}

/// Simple usage bar for legacy Antigravity readings (`GetUserStatus` / IDE) that report remaining
/// fraction and reset time without an explicit 5-hour / weekly cadence.
private struct FallbackQuotaRow: View {
    let usedPercent: Double
    let resetsAt: Date?
    let description: String?
    let now: Date
    let strings: Strings
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(UsageFormatter.percent(usedPercent))
                    .font(.callout.monospacedDigit())
                Spacer()
                if let resetsAt {
                    Text(strings.resetsLine(clock(resetsAt), UsageFormatter.countdown(to: resetsAt, from: now)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(usedPercent >= 95 ? Color.red : Color.accentColor)
                        .frame(width: CGFloat(max(0, min(1, usedPercent / 100))) * geo.size.width)
                }
            }
            .frame(height: 8)
        }
    }

    private func clock(_ date: Date) -> String {
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(time)
        }
        return date.formatted(time.month(.abbreviated).day())
    }
}
