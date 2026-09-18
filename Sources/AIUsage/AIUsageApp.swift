import AIUsageCore
import SwiftUI

@main
struct AIUsageApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var updater = Updater()

    init() {
        // Debug entry point: `AIUsage --probe` runs one active query, prints the
        // snapshot as JSON, and exits without touching the menu bar.
        if CommandLine.arguments.contains("--probe") {
            Self.runProbeAndExit()
        }
        // No Dock icon. The .app also sets LSUIElement, but this makes the bare
        // `swift run` binary behave the same way.
        NSApplication.shared.setActivationPolicy(.accessory)
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

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .environmentObject(updater)
        } label: {
            Text(store.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updater)
        }
    }
}
