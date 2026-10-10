import AIUsageCore
import SwiftUI

/// One page of the Settings window. The tabs themselves are the window's toolbar, which
/// `SettingsPresenter` builds, the way macOS settings windows look.
struct SettingsView: View {
    enum Tab: CaseIterable {
        case general, claudeCode, codex, deepseek

        func title(_ s: Strings) -> String {
            switch self {
            case .general: return s.general
            case .claudeCode: return s.claudeCode
            case .codex: return "Codex"
            case .deepseek: return "DeepSeek"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .claudeCode: return "terminal"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .deepseek: return "creditcard"
            }
        }
    }

    static let minWidth: CGFloat = 460

    let tab: Tab
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore
    @EnvironmentObject var codex: CodexStore
    @EnvironmentObject var updater: Updater

    private var s: Strings { store.strings }

    var body: some View {
        Group {
            switch tab {
            case .general: generalTab
            case .claudeCode: claudeCodeTab
            case .codex: codexTab
            case .deepseek: deepseekTab
            }
        }
        // Opens at its natural size and follows the window when it is resized.
        .frame(minWidth: Self.minWidth, idealWidth: Self.minWidth, maxWidth: .infinity, maxHeight: .infinity)
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

            layoutSection

            // The 5h/7d choice only matters while the menu bar shows Claude or Codex.
            if !Set(store.layout.menuBar(enabled: enabledProviders)).isDisjoint(with: [.claude, .codex]) {
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
                    Toggle(isOn: $store.notifyQuotaRestored) {
                        Text(s.notifyQuotaRestored)
                        Text(s.notifyQuotaRestoredHint)
                    }
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

    // MARK: Layout

    private var enabledProviders: Set<Provider> {
        var set: Set<Provider> = [.claude]
        if codex.enabled { set.insert(.codex) }
        if deepseek.enabled { set.insert(.deepseek) }
        return set
    }

    private var layoutSection: some View {
        Section {
            let order = store.layout.order
            ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                layoutRow(provider, index: index, count: order.count)
            }
        } header: {
            Text(s.layout)
            Text(s.layoutHint)
        }
    }

    private func layoutRow(_ provider: Provider, index: Int, count: Int) -> some View {
        let enabled = enabledProviders.contains(provider)
        // The menu bar must keep at least one item, or there is nothing left to click.
        let onlyMenuBarItem = store.layout.menuBar(enabled: enabledProviders) == [provider]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name(provider))
                if !enabled, let tab = settingsTab(provider) {
                    Text(s.layoutProviderOff(tab.title(s))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(s.layoutPanel, isOn: Binding(
                get: { !store.layout.hiddenInPanel.contains(provider) },
                set: { shown in
                    if shown { store.layout.hiddenInPanel.remove(provider) } else { store.layout.hiddenInPanel.insert(provider) }
                }))
                .toggleStyle(.checkbox)
                .disabled(!enabled)
            Toggle(s.layoutMenuBar, isOn: Binding(
                get: { enabled && store.layout.menuBar(enabled: enabledProviders).contains(provider) },
                set: { shown in
                    // Write the effective set, so unticking the fallback item behaves as shown.
                    var chosen = Set(store.layout.menuBar(enabled: enabledProviders))
                    if shown { chosen.insert(provider) } else { chosen.remove(provider) }
                    store.layout.inMenuBar = chosen
                }))
                .toggleStyle(.checkbox)
                .disabled(!enabled || onlyMenuBarItem)
            HStack(spacing: 2) {
                Button { store.layout.move(provider, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help(s.layoutMoveUp)
                Button { store.layout.move(provider, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
                    .help(s.layoutMoveDown)
            }
            .buttonStyle(.borderless)
        }
    }

    private func name(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        }
    }

    /// Where a provider is switched on; Claude has no switch.
    private func settingsTab(_ provider: Provider) -> Tab? {
        switch provider {
        case .claude: return nil
        case .codex: return .codex
        case .deepseek: return .deepseek
        }
    }

    // MARK: Codex

    private var codexTab: some View {
        Form {
            Section {
                Toggle(isOn: $codex.enabled) {
                    Text(s.codexEnable)
                    Text(s.codexEnableHint)
                }
            }

            Section {
                TextField(s.codexPath, text: $codex.pathOverride,
                          prompt: Text(codex.resolvedPath ?? s.codexPathPlaceholder))
                    .font(.callout.monospaced())
                HStack(alignment: .top) {
                    if let error = codex.lastError {
                        Text(error).font(.caption).foregroundStyle(codex.errorIsMinor ? Color.secondary : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let summary = codexSummary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if codex.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Button(s.codexRefresh) { codex.refresh() }
                        .disabled(!codex.enabled || codex.isRefreshing)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Plus · 5h 6% · 7d 12%"
    private var codexSummary: String? {
        guard let usage = codex.usage else { return nil }
        let windows = usage.windows.map { "\($0.kind.shortLabel) \(UsageFormatter.percent($0.usedPercent))" }
        return ([codex.planLabel].compactMap { $0 } + windows).joined(separator: " · ")
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
                    SecureField(s.deepseekAPIKey, text: $deepseek.apiKeyDraft,
                                prompt: Text(deepseek.hasAPIKey ? "••••••••" : "sk-…"))
                        .onSubmit(deepseek.saveTypedAPIKey)
                    Button(s.deepseekSave, action: deepseek.saveTypedAPIKey).disabled(deepseek.apiKeyDraft.isEmpty)
                }
                HStack {
                    Text(deepseek.apiKeyJustSaved ? s.deepseekAPIKeySaved : s.deepseekAPIKeyHint)
                        .font(.caption).foregroundStyle(deepseek.apiKeyJustSaved ? .green : .secondary)
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
