import AIUsageCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore
    @EnvironmentObject var updater: Updater
    @State private var apiKeyDraft = ""
    @State private var apiKeyJustSaved = false

    private var s: Strings { store.strings }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(s.general, systemImage: "gearshape") }
            claudeCodeTab
                .tabItem { Label(s.claudeCode, systemImage: "terminal") }
            deepseekTab
                .tabItem { Label("DeepSeek", systemImage: "creditcard") }
        }
        .frame(width: 460)
        .padding(.bottom, 4)
        .onAppear { store.refreshNotificationStatus() }
    }

    private var generalTab: some View {
        Form {
            Picker(selection: $store.language) {
                Text(s.languageSystem).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.en)
                Text("中文").tag(AppLanguage.zh)
            } label: {
                Text(s.language)
                Text(s.languageRelaunchHint)
            }

            if deepseek.enabled {
                Picker(s.menuBarProvider, selection: $store.menuBarProvider) {
                    Text("Claude").tag(UsageStore.MenuBarProvider.claude)
                    Text("DeepSeek").tag(UsageStore.MenuBarProvider.deepseek)
                }
                .pickerStyle(.segmented)
            }

            // The 5h/7d choice only matters while the menu bar shows Claude.
            if !deepseek.enabled || store.menuBarProvider == .claude {
                Picker(s.menuBarShows, selection: $store.menuBarKind) {
                    ForEach(WindowKind.allCases, id: \.self) { kind in
                        Text(kind.shortLabel).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $store.compactMenuBar) {
                Text(s.compactMenuBar)
                Text(s.compactMenuBarHint)
            }

            if store.loginItemSupported {
                Toggle(s.launchAtLogin, isOn: $store.launchAtLogin)
            }

            if store.notificationsSupported {
                Section(s.notifications) {
                    Toggle(isOn: $store.notifyOverPace) {
                        Text(s.notifyOverPace)
                        Text(s.notifyOverPaceHint)
                    }
                    Toggle(isOn: $store.notifyRunningOut) {
                        Text(s.notifyRunningOut)
                        Text(s.notifyRunningOutHint)
                    }
                    Toggle(s.notifyWindowReset, isOn: $store.notifyWindowReset)
                    if store.notificationStatus.denied || store.notificationStatus.bannersOff {
                        HStack(alignment: .top) {
                            Text(store.notificationStatus.denied ? s.notificationsDenied : s.notificationsBannersOff)
                                .font(.caption)
                                .foregroundStyle(store.notificationStatus.denied ? .red : .orange)
                            Spacer()
                            Button(s.openNotificationSettings) { store.openNotificationSettings() }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(s.sendTestNotification) { store.sendTestNotification() }
                    }
                }
            }

            Section(s.updates) {
                if updater.available {
                    Toggle(s.autoCheckForUpdates, isOn: $updater.automaticallyChecks)
                    HStack {
                        Spacer()
                        Button(s.checkForUpdates) { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                } else {
                    Text(s.updatesUnavailable).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var deepseekTab: some View {
        Form {
            Section {
                Toggle(isOn: $deepseek.enabled) {
                    Text(s.deepseekEnable)
                    Text(s.deepseekEnableHint)
                }
            }

            Section {
                HStack {
                    SecureField(s.deepseekAPIKey, text: $apiKeyDraft,
                                prompt: Text(deepseek.hasAPIKey ? "••••••••" : "sk-…"))
                        .onSubmit(saveKey)
                    Button(s.deepseekSave, action: saveKey).disabled(apiKeyDraft.isEmpty)
                }
                HStack {
                    Text(apiKeyJustSaved ? s.deepseekAPIKeySaved : s.deepseekAPIKeyHint)
                        .font(.caption).foregroundStyle(apiKeyJustSaved ? .green : .secondary)
                    Spacer()
                    Button(s.deepseekRefresh) { deepseek.refresh() }
                        .disabled(!deepseek.hasAPIKey || deepseek.isRefreshing)
                }
                if let error = deepseek.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let latest = deepseek.latest {
                    Text("\(s.deepseekBalance): \(deepseek.money(latest.total))").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: $deepseek.budgetEnabled) {
                    Text(s.deepseekMonthlyBudget)
                    Text(s.deepseekMonthlyBudgetHint)
                }
                if deepseek.budgetEnabled {
                    TextField(s.deepseekMonthlyBudgetAmount, value: $deepseek.monthlyBudget, format: .number)
                }
            }

            Section {
                TextField(s.deepseekLowBalance, value: $deepseek.lowBalanceThreshold, format: .number)
                Toggle(s.deepseekNotifyLowBalance, isOn: $deepseek.notifyLowBalance)
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        guard !apiKeyDraft.isEmpty else { return }
        deepseek.saveAPIKey(apiKeyDraft)
        apiKeyDraft = ""
        apiKeyJustSaved = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            apiKeyJustSaved = false
        }
    }

    private var claudeCodeTab: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: store.hookInstalled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(store.hookInstalled ? Color.green : Color.secondary)
                    Text(store.hookInstalled ? s.hookInstalled : s.hookNotInstalled)
                    Spacer()
                    Button(store.hookInstalled ? s.reinstall : s.install) {
                        store.installHook()
                    }
                }
                Text(s.hookHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = store.hookError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle(isOn: $store.showInClaudeCode) {
                    Text(s.showInClaudeCode)
                    Text(s.showInClaudeCodeHint)
                }
                .disabled(!store.hookInstalled)
            }

            Section {
                TextField(s.claudePath, text: $store.claudePathOverride,
                          prompt: Text(store.resolvedClaudePath ?? s.claudePathPlaceholder))
                    .font(.callout.monospaced())
            }

            Section {
                Text(s.precisionNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
