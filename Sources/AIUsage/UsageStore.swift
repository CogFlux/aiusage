import AIUsageCore
import AppKit
import Combine
import Foundation

/// Single source of truth for the UI. Holds the latest snapshot from either source,
/// a `now` that ticks so pace re-renders as time passes, and the state of the two
/// user actions (probe, hook install).
@MainActor
final class UsageStore: ObservableObject {
    enum ProbeState: Equatable {
        case idle
        case running
        case failed(String)
    }

    private enum Keys {
        static let claudePath = "claudePath"
        static let menuBarKind = "menuBarKind"
        static let language = "language"
        static let compactMenuBar = "compactMenuBar"
        static let notifyOverPace = "notifyOverPace"
        static let notifyRunningOut = "notifyRunningOut"
        static let notifyWindowReset = "notifyWindowReset"
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var now = Date()
    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var hookInstalled = false
    @Published private(set) var hookError: String?
    /// The statusline file exists and parses, but carries no `rate_limits` — typically an API-key account.
    @Published private(set) var fileHasNoQuota = false

    @Published var claudePathOverride: String {
        didSet { UserDefaults.standard.set(claudePathOverride, forKey: Keys.claudePath) }
    }

    @Published var menuBarKind: WindowKind {
        didSet { UserDefaults.standard.set(menuBarKind.rawValue, forKey: Keys.menuBarKind) }
    }

    @Published var language: AppLanguage {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(language.rawValue, forKey: Keys.language)
            Strings.current = strings
            // Our own strings switch immediately; system frameworks (Sparkle's dialogs,
            // standard alerts) read AppleLanguages at launch, so they follow after a relaunch.
            switch language {
            case .system: defaults.removeObject(forKey: "AppleLanguages")
            case .en: defaults.set(["en"], forKey: "AppleLanguages")
            case .zh: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
            }
        }
    }

    @Published var compactMenuBar: Bool {
        didSet { UserDefaults.standard.set(compactMenuBar, forKey: Keys.compactMenuBar) }
    }

    /// Backed by a flag file the hook script reads, not by UserDefaults.
    @Published var showInClaudeCode: Bool {
        didSet {
            do {
                try HookInstaller.setShowsLineInClaudeCode(showInClaudeCode)
                hookError = nil
            } catch {
                hookError = error.localizedDescription
            }
        }
    }

    // MARK: Notifications & login item

    @Published var notifyOverPace: Bool { didSet { notificationSettingChanged(notifyOverPace, key: Keys.notifyOverPace) } }
    @Published var notifyRunningOut: Bool { didSet { notificationSettingChanged(notifyRunningOut, key: Keys.notifyRunningOut) } }
    @Published var notifyWindowReset: Bool { didSet { notificationSettingChanged(notifyWindowReset, key: Keys.notifyWindowReset) } }
    @Published private(set) var notificationStatus = Notifier.Status()

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            do { try LoginItem.setEnabled(launchAtLogin) } catch { launchAtLogin = LoginItem.isEnabled }
        }
    }
    var loginItemSupported: Bool { LoginItem.isSupported }

    private let notifier = Notifier()
    var notificationsSupported: Bool { notifier.isSupported }
    private var alertTracker = AlertTracker()

    var strings: Strings { Strings.forLanguage(language.resolved) }
    var locale: Locale { language.resolved.locale }

    let config = PaceConfig()
    /// Data older than this gets a ⧗ marker in the menu bar.
    let staleAfter: TimeInterval = 30 * 60

    private var watcher: DirectoryWatcher?
    private var ticker: Timer?

    init() {
        let defaults = UserDefaults.standard
        claudePathOverride = defaults.string(forKey: Keys.claudePath) ?? ""
        menuBarKind = WindowKind(rawValue: defaults.string(forKey: Keys.menuBarKind) ?? "") ?? .fiveHour
        let storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        language = storedLanguage
        compactMenuBar = defaults.bool(forKey: Keys.compactMenuBar)
        showInClaudeCode = HookInstaller.showsLineInClaudeCode
        notifyOverPace = defaults.bool(forKey: Keys.notifyOverPace)
        notifyRunningOut = defaults.bool(forKey: Keys.notifyRunningOut)
        notifyWindowReset = defaults.bool(forKey: Keys.notifyWindowReset)
        launchAtLogin = LoginItem.isEnabled
        Strings.current = Strings.forLanguage(storedLanguage.resolved)

        refreshHookState()
        reloadFromFile()
        startWatching()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        evaluateAlerts()
        if notifyOverPace || notifyRunningOut || notifyWindowReset {
            refreshNotificationStatus()
        }
    }

    /// Re-reads the system authorization so the Settings hints follow changes the user makes in
    /// System Settings without a relaunch. Called on tick, on Settings appearing, and after requests.
    func refreshNotificationStatus() {
        guard notifier.isSupported else { return }
        Task {
            let status = await notifier.status()
            if status != notificationStatus { notificationStatus = status }
        }
    }

    func openNotificationSettings() {
        if let url = Notifier.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func notificationSettingChanged(_ enabled: Bool, key: String) {
        UserDefaults.standard.set(enabled, forKey: key)
        guard enabled else { return }
        Task {
            _ = await notifier.requestAuthorization()
            refreshNotificationStatus()
        }
    }

    /// Fires a sample over-pace alert for the menu bar window so the user can confirm permissions.
    func sendTestNotification() {
        Task {
            let granted = await notifier.requestAuthorization()
            refreshNotificationStatus()
            guard granted else { return }
            let resets = Date().addingTimeInterval(2 * 3600)
            let window = UsageWindow(kind: menuBarKind, usedPercent: 42, resetsAt: resets)
            let pace = Pace(usedPercent: 42, elapsedFraction: 0.33, budgetPercent: 33, deltaPercent: 9,
                            projectedPercent: 126, runoutAt: nil, status: .overPace)
            notifier.deliver(UsageAlert(kind: .overPace, window: window.kind, resetsAt: resets, pace: pace),
                             strings: strings, locale: locale)
        }
    }

    /// Runs on every new snapshot and every clock tick. The tracker dedupes; here we only filter
    /// by the user's toggles and hand the rest to the notifier.
    private func evaluateAlerts() {
        let alerts = alertTracker.evaluate(snapshot: snapshot, now: now, paceConfig: config)
        for alert in alerts {
            let enabled: Bool
            switch alert.kind {
            case .overPace: enabled = notifyOverPace
            case .runningOut: enabled = notifyRunningOut
            case .windowReset: enabled = notifyWindowReset && alert.window == .fiveHour
            }
            if enabled {
                notifier.deliver(alert, strings: strings, locale: locale)
            }
        }
    }

    // MARK: Derived state

    func pace(for kind: WindowKind) -> Pace? {
        snapshot?.window(kind).map { PaceCalculator.compute(window: $0, now: now, config: config) }
    }

    var isStale: Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.observedAt) > staleAfter
    }

    var menuBarTitle: String {
        UsageFormatter.menuBarTitle(kind: menuBarKind, pace: pace(for: menuBarKind), stale: isStale,
                                    compact: compactMenuBar)
    }

    var resolvedClaudePath: String? {
        ClaudeProbe.resolveClaudePath(override: claudePathOverride)
    }

    /// True when a `claude` executable is reachable (default locations, login-shell PATH, or the override).
    var claudeCodeInstalled: Bool { resolvedClaudePath != nil }

    static let claudeCodeInstallURL = URL(string: "https://code.claude.com/docs/en/quickstart")!

    // MARK: Passive source (statusline file)

    func reloadFromFile() {
        let url = HookInstaller.statuslineFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url) else { return }
        do {
            if let parsed = try StatuslineParser.parse(data, observedAt: mtime) {
                fileHasNoQuota = false
                merge(parsed)
            } else {
                // Valid statusline JSON without rate_limits.
                fileHasNoQuota = true
            }
        } catch {
            // Unreadable JSON, e.g. a partially written file; keep what we have.
        }
    }

    private func startWatching() {
        try? FileManager.default.createDirectory(at: HookInstaller.supportDir, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: HookInstaller.supportDir) { [weak self] in
            self?.reloadFromFile()
        }
    }

    /// Relative age of the current snapshot in the selected language, e.g. "3 minutes ago".
    var snapshotAge: String? {
        guard let snapshot else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.observedAt, relativeTo: now)
    }

    /// See `UsageSnapshot.merging` for the rule.
    private func merge(_ incoming: UsageSnapshot) {
        snapshot = snapshot?.merging(incoming) ?? incoming
        now = Date()
        evaluateAlerts()
    }

    // MARK: Active source (claude -p probe)

    func probe() {
        guard probeState != .running else { return }
        guard let path = resolvedClaudePath else {
            let overrideSet = !claudePathOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            probeState = .failed(overrideSet ? strings.probeClaudePathInvalid : strings.probeClaudeNotInstalled)
            return
        }
        probeState = .running
        let env = HookInstaller.settingsEnv()
        Task {
            do {
                let snap = try await ClaudeProbe.run(claudePath: path, extraEnv: env)
                merge(snap)
                probeState = .idle
            } catch {
                probeState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Hook

    func installHook() {
        do {
            try HookInstaller.install()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    func refreshHookState() {
        hookInstalled = HookInstaller.isInstalled()
    }
}
