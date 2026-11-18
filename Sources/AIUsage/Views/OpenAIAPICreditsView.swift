import SwiftUI

struct OpenAIAPICreditsSettings: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var credits: OpenAIAPICreditsStore

    private var s: Strings { store.strings }

    var body: some View {
        Section {
            Toggle(isOn: $credits.enabled) {
                Text(s.openAIAPICreditsEnable)
                Text(s.openAIAPICreditsHint)
            }
            if credits.enabled {
                HStack {
                    SecureField(s.openAIAPIAdminKey, text: $credits.apiKeyDraft,
                                prompt: Text(credits.hasAPIKey ? "••••••••" : "sk-admin-…"))
                        .onSubmit(credits.saveKey)
                    Button(s.deepseekSave, action: credits.saveKey)
                        .disabled(credits.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if credits.hasAPIKey {
                        Button(s.openAIAPIRemoveKey, action: credits.removeKey)
                    }
                }
                Text(s.openAIAPIKeyHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(s.openAIAPIAllowance, value: $credits.allowance, format: .number.locale(store.locale))
                if let cycle = credits.cycle {
                    LabeledContent(credits.isRenewalEstimated ? s.openAIAPIEstimatedRenewal : s.openAIAPISubscriptionRenewal,
                                   value: cycle.end.formatted(.dateTime.month(.abbreviated).day().locale(store.locale)))
                } else {
                    Text(s.openAIAPICycleUnavailable).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Link(s.openAIAPICreateKey, destination: OpenAIAPICreditsStore.adminKeysURL)
                    Spacer()
                    Link(s.openAIAPIBilling, destination: OpenAIAPICreditsStore.billingURL)
                }
                if let issue = credits.issue {
                    Text(s.openAIAPIIssue(issue)).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text(s.openAIAPICreditsTitle)
        }
    }
}

struct OpenAIAPICreditsRow: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var credits: OpenAIAPICreditsStore

    private var s: Strings { store.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.openAIAPICreditsTitle).font(.headline)
                Spacer()
                if credits.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let updatedAt = credits.updatedAt {
                    let timestamp = updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(store.locale))
                    Text(store.readingAge(updatedAt, relativeTo: credits.now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(s.openAIAPIUpdated(timestamp))
                }
                Button(action: credits.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(s.codexRefresh)
                .help(s.codexRefresh)
                .disabled(credits.isRefreshing || !credits.hasAPIKey || credits.allowance <= 0)
            }
            if let spend = credits.spend, let window = credits.budgetWindow {
                let allowance = credits.allowance
                HStack(spacing: 8) {
                    Text(s.openAIAPISpend(money(spend), money(allowance)))
                    Spacer()
                    Text(s.openAIAPIRemaining(money(max(0, allowance - spend))))
                        .foregroundStyle(.secondary)
                }
                .font(.caption).monospacedDigit()
                WindowRow(kind: .month, window: window, pace: credits.pace, idle: false,
                          now: credits.now, strings: s, locale: store.locale,
                          repace: .init(available: credits.canRepace, automatic: false,
                                        start: credits.repaceFromNow, clear: credits.clearCheckpoint),
                          resetLabel: credits.isRenewalEstimated ? s.openAIAPIEstimatedReset : nil)
            }
            if let issue = credits.issue {
                Text(s.openAIAPIIssue(issue)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !credits.hasAPIKey || credits.allowance <= 0 {
                Text(s.openAIAPISetup).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if credits.cycle == nil {
                Text(s.openAIAPICycleUnavailable).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if credits.spend == nil {
                Text(s.waitingForData).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").locale(store.locale))
    }
}
