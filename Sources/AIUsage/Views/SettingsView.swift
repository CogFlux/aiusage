import AIUsageCore
import SwiftUI

/// One page of the Settings window. The tabs themselves are the window's toolbar, which
/// `SettingsPresenter` builds, the way macOS settings windows look.
struct SettingsView: View {
    enum Tab: CaseIterable {
        case general, claudeCode, codex, opencodeGo, deepseek, sync

        func title(_ s: Strings) -> String {
            switch self {
            case .general: return s.general
            case .claudeCode: return s.claudeCode
            case .codex: return "Codex"
            case .opencodeGo: return "OpenCode Go"
            case .deepseek: return "DeepSeek"
            case .sync: return s.syncTab
            }
        }

        /// The provider whose logo marks the tab; nil for the others, which use `symbol`.
        var provider: Provider? {
            switch self {
            case .claudeCode: return .claude
            case .codex: return .codex
            case .opencodeGo: return .opencodego
            case .deepseek: return .deepseek
            case .general, .sync: return nil
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .claudeCode: return "terminal"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .opencodeGo: return "curlybraces"
            case .deepseek: return "creditcard"
            case .sync: return "arrow.up.circle"
            }
        }
    }

    static let minWidth: CGFloat = 460

    let tab: Tab
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var deepseek: DeepSeekStore
    @EnvironmentObject var codex: CodexStore
    @EnvironmentObject var opencodeGo: OpenCodeGoStore
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var sync: SyncStore

    private var s: Strings { store.strings }

    var body: some View {
        Group {
            switch tab {
            case .general: generalTab
            case .claudeCode: claudeCodeTab
            case .codex: codexTab
            case .opencodeGo: opencodeGoTab
            case .deepseek: deepseekTab
            case .sync: syncTab
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

            // The 5h/7d choice only matters while the menu bar shows a provider with those windows.
            if !Set(store.layout.menuBar(enabled: enabledProviders)).isDisjoint(with: [.claude, .codex, .opencodego]) {
                Picker(s.menuBarShows, selection: $store.menuBarKind) {
                    ForEach(WindowKind.claudeKinds, id: \.self) { kind in
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
        var set: Set<Provider> = store.enabled ? [.claude] : []
        if codex.enabled { set.insert(.codex) }
        if deepseek.enabled { set.insert(.deepseek) }
        if opencodeGo.enabled { set.insert(.opencodego) }
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
                Text(provider.displayName)
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

    /// Where a provider is switched on.
    private func settingsTab(_ provider: Provider) -> Tab? {
        switch provider {
        case .claude: return .claudeCode
        case .codex: return .codex
        case .deepseek: return .deepseek
        case .opencodego: return .opencodeGo
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

            // Everything below follows the switch above.
            Group {
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
                            .disabled(codex.isRefreshing)
                    }
                }
            }
            .disabled(!codex.enabled)
        }
        .formStyle(.grouped)
    }

    /// "Plus · 5h 6% · 7d 12%"
    private var codexSummary: String? {
        guard let usage = codex.usage else { return nil }
        let windows = usage.windows.map { "\($0.kind.shortLabel) \(UsageFormatter.percent($0.usedPercent))" }
        let until = codex.subscription?.activeUntil.map {
            s.codexPaidThrough($0.formatted(Date.FormatStyle.dateTime.month(.abbreviated).day().locale(store.locale)))
        }
        return ([codex.planLabel].compactMap { $0 } + windows + [until].compactMap { $0 }).joined(separator: " · ")
    }

    // MARK: OpenCode Go

    private var opencodeGoTab: some View {
        Form {
            Section {
                Toggle(isOn: $opencodeGo.enabled) {
                    Text(s.opencodeGoEnable)
                    Text(s.opencodeGoEnableHint)
                }
            }

            // Everything below follows the switch above.
            Group {
                Section {
                    HStack {
                        SecureField(s.deepseekAPIKey, text: $opencodeGo.apiKeyDraft,
                                    prompt: Text(opencodeGo.hasAPIKey ? "••••••••" : "oc_sk_…"))
                            .onSubmit(opencodeGo.saveTypedAPIKey)
                        Button(s.deepseekSave, action: opencodeGo.saveTypedAPIKey)
                            .disabled(opencodeGo.apiKeyDraft.isEmpty)
                    }
                    Text(opencodeGo.apiKeyJustSaved ? s.deepseekAPIKeySaved : s.opencodeGoAPIKeyHint)
                        .font(.caption).foregroundStyle(opencodeGo.apiKeyJustSaved ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        if let error = opencodeGo.lastError {
                            Text(error).font(.caption)
                                .foregroundStyle(opencodeGo.errorIsMinor ? Color.secondary : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let summary = opencodeGoSummary {
                            Text(summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if opencodeGo.isRefreshing {
                            ProgressView().controlSize(.small)
                        }
                        Button(s.codexRefresh) { opencodeGo.refresh() }
                            .disabled(!opencodeGo.hasAPIKey || opencodeGo.isRefreshing)
                    }
                }
            }
            .disabled(!opencodeGo.enabled)
        }
        .formStyle(.grouped)
    }

    /// "5h 6% · 7d 12% · mo 3%"
    private var opencodeGoSummary: String? {
        guard let usage = opencodeGo.usage else { return nil }
        return usage.windows.map { "\($0.kind.shortLabel) \(UsageFormatter.percent($0.usedPercent))" }
            .joined(separator: " · ")
    }

    private var deepseekTab: some View {
        Form {
            Section {
                Toggle(isOn: $deepseek.enabled) {
                    Text(s.deepseekEnable)
                    Text(s.deepseekEnableHint)
                }
            }

            // Everything below follows the switch above.
            Group {
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
            .disabled(!deepseek.enabled)
        }
        .formStyle(.grouped)
    }

    // MARK: Sync

    private var syncTab: some View {
        Form {
            Section {
                Toggle(isOn: $sync.enabled) {
                    Text(s.syncEnable)
                    Text(s.syncEnableHint)
                }
            }

            // Everything below follows the switch above.
            Group {
                Section {
                    TextField(s.syncEndpoint, text: $sync.endpoint, prompt: Text(SyncStore.endpointPlaceholder))
                        .font(.callout.monospaced())
                    if !sync.endpoint.isEmpty, !sync.endpointIsValid {
                        Text(s.syncInsecureEndpoint).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        SecureField(s.syncToken, text: $sync.tokenDraft, prompt: Text(sync.hasToken ? "••••••••" : "usg_…"))
                            .onSubmit(sync.saveTypedToken)
                        Button(s.deepseekSave, action: sync.saveTypedToken).disabled(sync.tokenDraft.isEmpty)
                    }
                    Text(sync.tokenJustSaved ? s.syncTokenSaved : s.syncTokenHint)
                        .font(.caption).foregroundStyle(sync.tokenJustSaved ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    TextField("Claude", text: $sync.claudeAccount, prompt: Text("claude"))
                    TextField("Codex", text: $sync.codexAccount, prompt: Text("codex"))
                } header: {
                    Text(s.syncAccounts)
                    Text(s.syncAccountsHint)
                }

                Section {
                    HStack(alignment: .top) {
                        if let error = sync.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(syncStatus).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sync.isSending {
                            ProgressView().controlSize(.small)
                        }
                        Button(s.syncSendNow) { sync.sendNow() }
                            .disabled(!sync.hasToken || !sync.endpointIsValid || sync.isSending)
                    }
                }
            }
            .disabled(!sync.enabled)
        }
        .formStyle(.grouped)
    }

    /// "Last upload 3 min ago · 2 waiting"
    private var syncStatus: String {
        var parts: [String] = []
        if let at = sync.lastSentAt {
            let f = RelativeDateTimeFormatter()
            f.locale = store.locale
            f.unitsStyle = .short
            parts.append(s.syncLastSent(f.localizedString(for: at, relativeTo: Date())))
        } else {
            parts.append(s.syncNeverSent)
        }
        if sync.queued > 0 { parts.append(s.syncQueued(sync.queued)) }
        return parts.joined(separator: " · ")
    }

    private var claudeCodeTab: some View {
        Form {
            Section {
                Toggle(isOn: $store.enabled) {
                    Text(s.claudeEnable)
                    Text(s.claudeEnableHint)
                }
            }

            // Everything below follows the switch above.
            Group {
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
                    Toggle(isOn: $store.oauthQueryEnabled) {
                        Text(s.oauthEnable)
                        Text(s.oauthEnableHint)
                    }
                    HStack(alignment: .top) {
                        Text(s.oauthRereadHint).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if store.probeState == .running {
                            ProgressView().controlSize(.small)
                        }
                        Button(s.oauthReread) { store.rereadOAuthSignIn() }
                            .disabled(!store.oauthQueryEnabled || store.probeState == .running)
                    }
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
            .disabled(!store.enabled)
        }
        .formStyle(.grouped)
    }
}
