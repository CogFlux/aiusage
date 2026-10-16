import AIUsageCore
import SwiftUI

/// The row of providers at the top of the panel, as in CodexBar: each one's logo over a thin bar
/// per window (5-hour, 7-day, then month), coloured by pace. Picking one shows its block below.
struct ProviderSwitcher: View {
    let providers: [Provider]
    let selected: Provider
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var codex: CodexStore
    @EnvironmentObject var deepseek: DeepSeekStore
    @EnvironmentObject var opencodeGo: OpenCodeGoStore

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(providers, id: \.self) { provider in
                tab(provider)
            }
        }
    }

    private func tab(_ provider: Provider) -> some View {
        let isSelected = provider == selected
        return Button {
            store.panelSelection = provider
        } label: {
            VStack(spacing: 4) {
                if let icon = ProviderIcon.image(provider) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                } else {
                    Text(provider.displayName.prefix(1)).font(.headline).frame(width: 18, height: 18)
                }
                readings(provider)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .help(provider.displayName)
    }

    /// One bar per window the provider reports. DeepSeek has no windows: its budget, when set,
    /// is paced like one; otherwise the balance is the only reading there is.
    @ViewBuilder
    private func readings(_ provider: Provider) -> some View {
        switch provider {
        case .claude: bars(WindowKind.claudeKinds.map { store.pace(for: $0) })
        case .codex: bars(WindowKind.claudeKinds.map { codex.pace(for: $0) })
        case .opencodego: bars(OpenCodeGoStore.kinds.map { opencodeGo.pace(for: $0) })
        case .deepseek:
            if let pace = deepseek.budgetPace {
                bars([pace])
            } else if let latest = deepseek.latest {
                Text(deepseek.money(latest.total, compact: true))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
        }
    }

    private func bars(_ paces: [Pace?]) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(paces.enumerated()), id: \.offset) { _, pace in
                MiniBar(pace: pace)
            }
        }
    }
}

/// A thin used-fraction bar; an empty track for a window with no reading.
private struct MiniBar: View {
    let pace: Pace?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            if let pace {
                Capsule().fill(color(pace.status)).frame(width: 36 * max(0, min(1, pace.usedPercent / 100)))
            }
        }
        .frame(width: 36, height: 3)
    }

    private func color(_ status: PaceStatus) -> Color {
        switch status {
        case .overPace: return .red
        case .underPace: return .green
        case .onTrack, .tooEarly: return .accentColor
        case .reset: return .gray
        }
    }
}
