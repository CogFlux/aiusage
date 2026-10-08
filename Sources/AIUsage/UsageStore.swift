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
        /// Superseded by `layout`; read once to carry the choice over.
        static let menuBarProvider = "menuBarProvider"
        static let layout = "providerLayout"
        static let checkpoints = "paceCheckpoints"
        static let restorePoints = "paceRestorePoints"
        static let lastSnapshot = "lastSnapshot"
        static let sessionTracker = "sessionTracker"
        static let alertTracker = "alertTracker"
        static let lastLive = "lastLiveReading"
    }

    /// Persisted, so a restart does not begin by believing whichever session happened to write the
    /// statusline file last. Without it the merge has no history to judge that file against — and
    /// after a quota credit the file may well hold a stale session's pre-credit number.
    @Published private(set) var snapshot: UsageSnapshot? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Keys.lastSnapshot) }
    }
    /// Persisted with the snapshot: a restart must still know which sessions are idle.
    private var sessionTracker = SessionTracker() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(sessionTracker), forKey: Keys.sessionTracker) }
    }
    /// The last reading straight from an API response. Idle sessions rewrite the file every minute,
    /// so the snapshot's own `observedAt` says nothing about how current the numbers are.
    struct LiveReading: Codable, Equatable {
        var source: SnapshotSource
        var at: Date
    }
    @Published private(set) var lastLive: LiveReading? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(lastLive), forKey: Keys.lastLive) }
    }
    @Published private(set) var now = Date()
    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var hookInstalled = false
    @Published private(set) var hookError: String?
    /// The statusline file exists and parses, but carries no `rate_limits` — typically an API-key account.
    @Published private(set) var fileHasNoQuota = false

    @Published var claudePathOverride: String {
        didSet {
            UserDefaults.standard.set(claudePathOverride, forKey: Keys.claudePath)
            refreshClaudePath()
        }
    }
    /// Looked up in the background: finding `claude` may take a login shell.
    @Published private(set) var resolvedClaudePath: String?
    @Published private(set) var claudePathResolved = false

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
    /// Which providers the menu and the menu bar show, in what order.
    @Published var layout: ProviderLayout {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: Keys.layout) }
    }
    var notificationsSupported: Bool { notifier.isSupported }
    /// Persisted, so a relaunch does not repeat notifications that already fired.
    private var alertTracker = AlertTracker()

    /// Re-pace points and quota-credit origins; see `CheckpointBook`.
    @Published private(set) var checkpoints = CheckpointBook() {
        didSet {
            let defaults = UserDefaults.standard
            if checkpoints.manual != oldValue.manual {
                defaults.set(CheckpointBook.encode(checkpoints.manual), forKey: Keys.checkpoints)
            }
            if checkpoints.restores != oldValue.restores {
                defaults.set(CheckpointBook.encode(checkpoints.restores), forKey: Keys.restorePoints)
            }
        }
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
        if let data = defaults.data(forKey: Keys.layout),
           let saved = try? JSONDecoder().decode(ProviderLayout.self, from: data) {
            layout = saved
        } else {
            // Before the layout existed the menu bar showed exactly one provider.
            let previous = Provider(rawValue: defaults.string(forKey: Keys.menuBarProvider) ?? "") ?? .claude
            layout = ProviderLayout(inMenuBar: [previous])
        }
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
        if let data = defaults.data(forKey: Keys.lastSnapshot),
           let remembered = try? JSONDecoder().decode(UsageSnapshot?.self, from: data) {
            snapshot = remembered
        }
        if let data = defaults.data(forKey: Keys.sessionTracker),
           let remembered = try? JSONDecoder().decode(SessionTracker.self, from: data) {
            sessionTracker = remembered
        }
        if let data = defaults.data(forKey: Keys.alertTracker),
           let remembered = try? JSONDecoder().decode(AlertTracker.self, from: data) {
            alertTracker = remembered
        }
        if let data = defaults.data(forKey: Keys.lastLive),
           let remembered = try? JSONDecoder().decode(LiveReading?.self, from: data) {
            lastLive = remembered
        }
        checkpoints = CheckpointBook(manual: CheckpointBook.decode(defaults.data(forKey: Keys.checkpoints)),
                                     restores: CheckpointBook.decode(defaults.data(forKey: Keys.restorePoints)))

        refreshHookState()
        refreshClaudePath()
        reloadFromFile()
        startWatching()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        evaluateAlerts()
        if notifyOverPace || notifyRunningOut || notifyWindowReset || notifyQuotaRestored {
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
        let before = alertTracker
        let alerts = alertTracker.evaluate(snapshot: snapshot, now: now, paceConfig: config,
                                           checkpoints: checkpoints.active(for: snapshot?.windows ?? []))
        if alertTracker != before {
            UserDefaults.standard.set(try? JSONEncoder().encode(alertTracker), forKey: Keys.alertTracker)
        }
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

    /// The origin in effect for `kind`, only while the window it was set on is the one reported.
    func checkpoint(for kind: WindowKind) -> PaceCheckpoint? {
        checkpoints.checkpoint(for: snapshot?.window(kind))
    }

    /// True when the pace origin in effect was placed by a quota credit rather than by the user.
    func checkpointIsAutomatic(_ kind: WindowKind) -> Bool {
        checkpoints.isAutomatic(snapshot?.window(kind))
    }

    /// Whether "re-pace from now" makes sense right now: a live window with quota left.
    func canRepace(_ kind: WindowKind) -> Bool {
        CheckpointBook.canRepace(snapshot?.window(kind), now: now, config: config)
    }

    func repaceFromNow(_ kind: WindowKind) {
        guard let window = snapshot?.window(kind), canRepace(kind) else { return }
        checkpoints.repace(window, now: now)
        evaluateAlerts()
    }

    func clearCheckpoint(_ kind: WindowKind) {
        checkpoints.clear(kind)
        evaluateAlerts()
    }

    /// When the numbers were last confirmed by an API response, and by which source. Falls back to
    /// the snapshot itself before any live reading has been seen.
    var confirmed: LiveReading? {
        lastLive ?? snapshot.map { LiveReading(source: $0.source, at: $0.observedAt) }
    }

    /// Nothing has confirmed the numbers for a while. They may still be right — or quota was spent
    /// where the statusline cannot see it (claude.ai, the desktop app).
    var isStale: Bool {
        guard snapshot != nil, let confirmed else { return false }
        return now.timeIntervalSince(confirmed.at) > staleAfter
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

    /// True when a `claude` executable is reachable (default locations, login-shell PATH, or the
    /// override). Assumed until the lookup says otherwise, so the warning does not flash at launch.
    var claudeCodeInstalled: Bool { !claudePathResolved || resolvedClaudePath != nil }

    func refreshClaudePath() {
        Task { _ = await lookUpClaudePath() }
    }

    private func lookUpClaudePath() async -> String? {
        let override = claudePathOverride
        let path = await Task.detached(priority: .userInitiated) {
            ClaudeProbe.resolveClaudePath(override: override)
        }.value
        // A newer lookup for a changed override has taken over.
        guard override == claudePathOverride else { return resolvedClaudePath }
        resolvedClaudePath = path
        claudePathResolved = true
        return path
    }

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

    /// Relative age of the last confirmed reading in the selected language, e.g. "3 minutes ago".
    var snapshotAge: String? {
        guard snapshot != nil, let confirmed else { return nil }
        if now.timeIntervalSince(confirmed.at) < 60 { return strings.justNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: confirmed.at, relativeTo: now)
    }

    /// See `MergePolicy` for the rule; the tracker says whether `incoming` is a live reading.
    private func merge(_ incoming: UsageSnapshot) {
        let provenance = sessionTracker.provenance(of: incoming)
        if provenance == .fresh {
            lastLive = LiveReading(source: incoming.source, at: incoming.observedAt)
        }
        let previous = snapshot
        snapshot = snapshot?.merging(incoming, provenance: provenance) ?? incoming
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
            // Only a change inside one instance is a new credit; switching to another account's
            // window brings that window's own, older credit along.
            guard let after = snapshot?.window(kind), let creditAt = after.creditAt,
                  let before = previous?.window(kind),
                  abs(before.resetsAt.timeIntervalSince(after.resetsAt)) <= MergePolicy().sameInstanceTolerance,
                  creditAt != before.creditAt else { continue }
            checkpoints.recordCredit(in: after, at: creditAt)
        }
    }

    // MARK: Active source (claude -p probe)

    func probe() {
        guard probeState != .running else { return }
        probeState = .running
        let env = HookInstaller.settingsEnv()
        Task {
            guard let path = await lookUpClaudePath() else {
                let overrideSet = !claudePathOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                probeState = .failed(overrideSet ? strings.probeClaudePathInvalid : strings.probeClaudeNotInstalled)
                return
            }
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
