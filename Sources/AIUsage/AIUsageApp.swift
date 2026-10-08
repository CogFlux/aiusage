import AIUsageCore
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store: UsageStore
    @StateObject private var deepseek: DeepSeekStore
    @StateObject private var codex: CodexStore
    @StateObject private var updater: Updater

    init() {
        // Debug entry point: `AIUsage --probe` runs one active query, prints the
        // snapshot as JSON, and exits without touching the menu bar.
        if CommandLine.arguments.contains("--probe") {
            Self.runProbeAndExit()
        }
        // Same for Codex: `AIUsage --codex-probe` reads its quota once (free) and prints it.
        if CommandLine.arguments.contains("--codex-probe") {
            Self.runCodexProbeAndExit()
        }
        // No Dock icon. The .app also sets LSUIElement, but this makes the bare
        // `swift run` binary behave the same way.
        NSApplication.shared.setActivationPolicy(.accessory)

        let notifier = Notifier()
        let store = UsageStore(notifier: notifier)
        _store = StateObject(wrappedValue: store)
        let deepseek = DeepSeekStore(notifier: notifier, strings: { store.strings }, locale: { store.locale })
        _deepseek = StateObject(wrappedValue: deepseek)
        let codex = CodexStore(notifier: notifier, strings: { store.strings }, locale: { store.locale })
        _codex = StateObject(wrappedValue: codex)
        let updater = Updater()
        _updater = StateObject(wrappedValue: updater)
        SettingsPresenter.configure(onOpen: { store.refreshNotificationStatus() }) { tab in
            SettingsView(tab: tab)
                .environmentObject(store)
                .environmentObject(deepseek)
                .environmentObject(codex)
                .environmentObject(updater)
        }
    }

    /// The chosen providers left to right, in the order set in Settings → General → Layout.
    private var menuBarTitle: String {
        ProviderLayout.joinMenuBar(store.layout.menuBar(enabled: enabledProviders).map { provider in
            switch provider {
            case .claude:
                return store.menuBarTitle
            case .codex:
                return codex.menuBarTitle(kind: store.menuBarKind, compact: store.compactMenuBar)
            case .deepseek:
                return deepseek.menuBarTitle(compact: store.compactMenuBar)
            }
        })
    }

    private var enabledProviders: Set<Provider> {
        var set: Set<Provider> = [.claude]
        if codex.enabled { set.insert(.codex) }
        if deepseek.enabled { set.insert(.deepseek) }
        return set
    }

    private static func runProbeAndExit() -> Never {
        let override = UserDefaults.standard.string(forKey: "claudePath") ?? ""
        guard let path = ClaudeProbe.resolveClaudePath(override: override) else {
            FileHandle.standardError.write(Data("claude not found\n".utf8))
            exit(2)
        }
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            defer { done.signal() }
            do {
                let snap = try await ClaudeProbe.run(claudePath: path, extraEnv: HookInstaller.settingsEnv())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(snap), as: UTF8.self))
                for kind in WindowKind.allCases {
                    if let w = snap.window(kind) {
                        let pace = PaceCalculator.compute(window: w, now: Date())
                        print(UsageFormatter.menuBarTitle(kind: kind, pace: pace, stale: false),
                              "budget \(UsageFormatter.percent(pace.budgetPercent))",
                              "delta \(UsageFormatter.signed(pace.deltaPercent))",
                              pace.projectedPercent.map { "projected \(UsageFormatter.percent($0))" } ?? "")
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }
        done.wait()
        exit(exitCode)
    }

    private static func runCodexProbeAndExit() -> Never {
        let override = UserDefaults.standard.string(forKey: "codexPath") ?? ""
        guard let path = CodexProbe.resolveCodexPath(override: override) else {
            FileHandle.standardError.write(Data("codex not found\n".utf8))
            exit(2)
        }
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            defer { done.signal() }
            do {
                let usage = try await CodexProbe.run(codexPath: path)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(usage), as: UTF8.self))
                for window in usage.windows {
                    let pace = PaceCalculator.compute(window: window, now: Date())
                    print("CX", UsageFormatter.menuBarTitle(kind: window.kind, pace: pace, stale: false))
                }
            } catch {
                FileHandle.standardError.write(Data("codex probe failed: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }
        done.wait()
        exit(exitCode)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .environmentObject(deepseek)
                .environmentObject(codex)
                .environmentObject(updater)
        } label: {
            Text(menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
