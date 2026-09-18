import AIUsageCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var updater: Updater

    private var s: Strings { store.strings }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(s.general, systemImage: "gearshape") }
            claudeCodeTab
                .tabItem { Label(s.claudeCode, systemImage: "terminal") }
        }
        .frame(width: 460)
        .padding(.bottom, 4)
    }

    private var generalTab: some View {
        Form {
            Picker(s.language, selection: $store.language) {
                Text(s.languageSystem).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.en)
                Text("中文").tag(AppLanguage.zh)
            }

            Picker(s.menuBarShows, selection: $store.menuBarKind) {
                ForEach(WindowKind.allCases, id: \.self) { kind in
                    Text(kind.shortLabel).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $store.compactMenuBar) {
                Text(s.compactMenuBar)
                Text(s.compactMenuBarHint)
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
