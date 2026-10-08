import AIUsageCore
import SwiftUI

/// Codex block in the popover: the plan's 5-hour and weekly windows, paced like Claude's.
struct CodexSection: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var codex: CodexStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !codex.codexInstalled {
                missing
            } else if let error = codex.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if codex.usage != nil {
                Divider()
                ForEach(WindowKind.allCases, id: \.self) { kind in
                    WindowRow(kind: kind,
                              window: codex.usage?.window(kind),
                              pace: codex.pace(for: kind),
                              idle: codex.isIdle(kind),
                              now: codex.now,
                              strings: s,
                              locale: store.locale,
                              // As for Claude: the weekly window is where an early overspend lingers.
                              repace: kind == .sevenDay
                                  ? .init(available: codex.canRepace(kind),
                                          automatic: codex.checkpointIsAutomatic(kind),
                                          start: { codex.repaceFromNow(kind) },
                                          clear: { codex.clearCheckpoint(kind) })
                                  : nil,
                              idleText: s.codexWindowIdle)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Codex").font(.title3.bold())
            if let plan = codex.planLabel {
                Text(plan)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            if codex.usage?.limitReached != nil {
                Text(s.codexLimitReached).font(.caption.bold()).foregroundStyle(.red)
            }
            Spacer()
            if codex.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let observed = codex.usage?.observedAt {
                Text(age(observed)).font(.caption)
                    .foregroundStyle(codex.isStale ? .orange : .secondary)
            } else {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
            // Free (no tokens), so a plain icon rather than Claude's button-with-cost-hint.
            Button {
                codex.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(s.codexRefresh)
            .disabled(codex.isRefreshing)
        }
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.codexNotInstalled).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(s.codexInstall) {
                NSWorkspace.shared.open(CodexStore.installURL)
            }
        }
    }

    private func age(_ date: Date) -> String {
        if codex.now.timeIntervalSince(date) < 60 { return s.justNow }
        let f = RelativeDateTimeFormatter()
        f.locale = store.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: codex.now)
    }
}
