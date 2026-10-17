import AIUsageCore
import SwiftUI

/// OpenCode Go block in the popover: the subscription's 5-hour, weekly and monthly windows, paced
/// like Claude's.
struct OpenCodeGoSection: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var go: OpenCodeGoStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = go.lastError {
                Text(error).font(.caption).foregroundStyle(go.errorIsMinor ? Color.secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !go.hasAPIKey {
                Text(s.opencodeGoNoKey).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.chartProviders.contains(.opencodego) {
                UsageChart(kinds: OpenCodeGoStore.kinds, history: go.history,
                           current: { go.usage?.window($0) },
                           checkpoint: { go.pace(for: $0)?.checkpoint },
                           now: go.now)
            }
            if go.usage != nil {
                Divider()
                ForEach(OpenCodeGoStore.kinds, id: \.self) { kind in
                    WindowRow(kind: kind,
                              window: go.usage?.window(kind),
                              pace: go.pace(for: kind),
                              idle: go.isIdle(kind),
                              now: go.now,
                              strings: s,
                              locale: store.locale,
                              // The long windows are where an early overspend lingers.
                              repace: kind == .fiveHour
                                  ? nil
                                  : .init(available: go.canRepace(kind),
                                          automatic: go.checkpointIsAutomatic(kind),
                                          start: { go.repaceFromNow(kind) },
                                          clear: { go.clearCheckpoint(kind) }),
                              idleText: s.opencodeGoWindowIdle)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("OpenCode Go").font(.title3.bold())
            if go.usage?.limitReached == true {
                Text(s.codexLimitReached).font(.caption.bold()).foregroundStyle(.red)
            }
            Spacer()
            if go.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let observed = go.usage?.observedAt {
                Text(age(observed)).font(.caption)
                    .foregroundStyle(go.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
            ChartToggle(provider: .opencodego)
            // Free (no tokens), so a plain icon, as for Codex.
            Button {
                go.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(s.codexRefresh)
            .disabled(go.isRefreshing || !go.hasAPIKey)
        }
    }

    private func age(_ date: Date) -> String {
        if go.now.timeIntervalSince(date) < 60 { return s.justNow }
        let f = RelativeDateTimeFormatter()
        f.locale = store.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: go.now)
    }
}
