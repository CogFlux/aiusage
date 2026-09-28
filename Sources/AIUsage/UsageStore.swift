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
        static let notifyQuotaRestored = "notifyQuotaRestored"
        static let menuBarProvider = "menuBarProvider"
        static let checkpoints = "paceCheckpoints"
        static let restorePoints = "paceRestorePoints"
    }

    /// A user-set "re-pace from now" point, bound to one window instance by its `resetsAt` so it
    /// silently expires when that window ends.
    struct StoredCheckpoint: Codable, Equatable {
        var resetsAt: Date
        var checkpoint: PaceCheckpoint
    }

    enum MenuBarProvider: String, CaseIterable {
        case claude
        case deepseek
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
    @Published var notifyQuotaRestored: Bool { didSet { notificationSettingChanged(notifyQuotaRestored, key: Keys.notifyQuotaRestored) } }
    @Published private(set) var notificationStatus = Notifier.Status()

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != LoginItem.isEnabled else { return }
            do { try LoginItem.setEnabled(launchAtLogin) } catch { launchAtLogin = LoginItem.isEnabled }
        }
    }
    var loginItemSupported: Bool { LoginItem.isSupported }

    let notifier: Notifier
    @Published var menuBarProvider: MenuBarProvider {
        didSet { UserDefaults.standard.set(menuBarProvider.rawValue, forKey: Keys.menuBarProvider) }
    }
    var notificationsSupported: Bool { notifier.isSupported }
    private var alertTracker = AlertTracker()

    @Published private(set) var storedCheckpoints: [WindowKind: StoredCheckpoint] = [:] {
        didSet { persist(storedCheckpoints, forKey: Keys.checkpoints) }
    }

    /// Where a quota reset credit landed, per window. The even-pace line is rebased onto it, so
    /// the default budget runs from the credit to 99% at the unchanged reset — what the restored
    /// quota actually has to be spent in — rather than reading "far under budget" until the window
    /// ends. This is a correction to the line, not a user setting: the UI shows no re-pace state
    /// for it. A checkpoint the user set by hand still wins.
    @Published private(set) var restorePoints: [WindowKind: StoredCheckpoint] = [:] {
        didSet { persist(restorePoints, forKey: Keys.restorePoints) }
    }

    private func persist(_ points: [WindowKind: StoredCheckpoint], forKey key: String) {
        let encoded = Dictionary(uniqueKeysWithValues: points.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(encoded), forKey: key)
    }

    private static func loadPoints(forKey key: String) -> [WindowKind: StoredCheckpoint] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: StoredCheckpoint].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            WindowKind(rawValue: key).map { ($0, value) }
        })
    }

    var strings: Strings { Strings.forLanguage(language.resolved) }
    var locale: Locale { language.resolved.locale }

    let config = PaceConfig()
    /// Data older than this gets a ⧗ marker in the menu bar.
    let staleAfter: TimeInterval = 30 * 60

    private var watcher: DirectoryWatcher?
    private var ticker: Timer?

    init(notifier: Notifier) {
        self.notifier = notifier
        let defaults = UserDefaults.standard
        menuBarProvider = MenuBarProvider(rawValue: defaults.string(forKey: Keys.menuBarProvider) ?? "") ?? .claude
        claudePathOverride = defaults.string(forKey: Keys.claudePath) ?? ""
        menuBarKind = WindowKind(rawValue: defaults.string(forKey: Keys.menuBarKind) ?? "") ?? .fiveHour
        let storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        language = storedLanguage
        compactMenuBar = defaults.bool(forKey: Keys.compactMenuBar)
        showInClaudeCode = HookInstaller.showsLineInClaudeCode
        notifyOverPace = defaults.bool(forKey: Keys.notifyOverPace)
        notifyRunningOut = defaults.bool(forKey: Keys.notifyRunningOut)
        notifyWindowReset = defaults.bool(forKey: Keys.notifyWindowReset)
        notifyQuotaRestored = defaults.bool(forKey: Keys.notifyQuotaRestored)
        launchAtLogin = LoginItem.isEnabled
        Strings.current = Strings.forLanguage(storedLanguage.resolved)
        storedCheckpoints = Self.loadPoints(forKey: Keys.checkpoints)
        restorePoints = Self.loadPoints(forKey: Keys.restorePoints)

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
            notifier.deliver(UsageAlert(kind: .overPace, windowID: "claude.\(window.kind.rawValue)", resetsAt: resets, pace: pace),
                             strings: strings, locale: locale)
        }
    }

    /// Runs on every new snapshot and every clock tick. The tracker dedupes; here we only filter
    /// by the user's toggles and hand the rest to the notifier.
    private func evaluateAlerts() {
        let alerts = alertTracker.evaluate(snapshot: snapshot, now: now, paceConfig: config,
                                           checkpoints: activeCheckpoints)
        for alert in alerts {
            let enabled: Bool
            switch alert.kind {
            case .overPace: enabled = notifyOverPace
            case .runningOut: enabled = notifyRunningOut
            case .windowReset: enabled = notifyWindowReset && alert.claudeWindow == .fiveHour
            case .quotaRestored: enabled = notifyQuotaRestored
            }
            if enabled {
                notifier.deliver(alert, strings: strings, locale: locale)
            }
        }
    }

    // MARK: Derived state

    func pace(for kind: WindowKind) -> Pace? {
        snapshot?.window(kind).map {
            PaceCalculator.compute(window: $0, now: now, config: config, checkpoint: checkpoint(for: kind))
        }
    }

    // MARK: Re-pace checkpoints

    /// The stored checkpoint for `kind`, but only while the window it was set on is the one
    /// currently reported. A statusline write and a probe may disagree on `resetsAt` by a
    /// second or two, so the match is loose.
    func checkpoint(for kind: WindowKind) -> PaceCheckpoint? {
        // The user's own re-pace wins; a credit deletes it, so the two never both apply.
        applicable(storedCheckpoints[kind], kind) ?? applicable(restorePoints[kind], kind)
    }

    /// True when the pace origin in effect was placed by a quota credit rather than by the user.
    func checkpointIsAutomatic(_ kind: WindowKind) -> Bool {
        applicable(storedCheckpoints[kind], kind) == nil && applicable(restorePoints[kind], kind) != nil
    }

    private func applicable(_ stored: StoredCheckpoint?, _ kind: WindowKind) -> PaceCheckpoint? {
        guard let stored, let window = snapshot?.window(kind),
              abs(window.resetsAt.timeIntervalSince(stored.resetsAt)) < 120,
              // Usage below the origin means another credit landed after it; `merge` clears those,
              // and this covers the moment before it runs.
              window.usedPercent >= stored.checkpoint.usedPercent else { return nil }
        return stored.checkpoint
    }

    private var activeCheckpoints: [WindowKind: PaceCheckpoint] {
        Dictionary(uniqueKeysWithValues: WindowKind.allCases.compactMap { kind in
            checkpoint(for: kind).map { (kind, $0) }
        })
    }

    /// Whether "re-pace from now" makes sense right now: a live window with quota left.
    func canRepace(_ kind: WindowKind) -> Bool {
        guard let window = snapshot?.window(kind) else { return false }
        return now < window.resetsAt && window.usedPercent < config.targetPercent
    }

    func repaceFromNow(_ kind: WindowKind) {
        guard let window = snapshot?.window(kind), canRepace(kind) else { return }
        storedCheckpoints[kind] = StoredCheckpoint(resetsAt: window.resetsAt,
                                                   checkpoint: PaceCheckpoint(at: now, usedPercent: window.usedPercent))
        restorePoints[kind] = nil
        evaluateAlerts()
    }

    /// Clears whichever origin is in effect, back to the plain line from the window start.
    func clearCheckpoint(_ kind: WindowKind) {
        storedCheckpoints[kind] = nil
        restorePoints[kind] = nil
        evaluateAlerts()
    }

    var isStale: Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.observedAt) > staleAfter
    }

    /// We have data from Claude, but this window is currently absent: it ended and the next
    /// message will start a new one.
    func isIdle(_ kind: WindowKind) -> Bool {
        snapshot != nil && snapshot?.window(kind) == nil
    }

    var menuBarTitle: String {
        UsageFormatter.menuBarTitle(kind: menuBarKind, pace: pace(for: menuBarKind), stale: isStale,
                                    compact: compactMenuBar, idle: isIdle(menuBarKind))
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
        if now.timeIntervalSince(snapshot.observedAt) < 60 { return strings.justNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.observedAt, relativeTo: now)
    }

    /// See `UsageSnapshot.merging` for the rule.
    private func merge(_ incoming: UsageSnapshot) {
        let previous = snapshot
        snapshot = snapshot?.merging(incoming) ?? incoming
        now = Date()
        recordQuotaRestores(since: previous)
        evaluateAlerts()
    }

    /// A quota reset credit zeroes usage without changing `resetsAt`. Two consequences: any
    /// checkpoint set earlier in the window is void — the amount it treats as sunk has come back,
    /// and deleting rather than ignoring it stops usage climbing past the old base from reviving a
    /// line anchored before the credit — and the credit itself becomes the sensible pace origin.
    private func recordQuotaRestores(since previous: UsageSnapshot?) {
        for kind in WindowKind.allCases {
            guard let before = previous?.window(kind), let after = snapshot?.window(kind),
                  abs(after.resetsAt.timeIntervalSince(before.resetsAt)) < 120,
                  before.usedPercent - after.usedPercent >= AlertConfig().quotaRestoredDropPoints else { continue }
            storedCheckpoints[kind] = nil
            restorePoints[kind] = StoredCheckpoint(resetsAt: after.resetsAt,
                                                   checkpoint: PaceCheckpoint(at: now, usedPercent: after.usedPercent))
        }
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
