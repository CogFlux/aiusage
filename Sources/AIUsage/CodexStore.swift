import AIUsageCore
import Combine
import Foundation

/// Codex (ChatGPT plan) quota. Reading it is free, so unlike Claude there is no passive source to
/// install and no paid "query now": the store simply polls `codex app-server` while enabled, and
/// paces the 5-hour and weekly windows with the same math and notifications as Claude's.
@MainActor
final class CodexStore: ObservableObject {
    private enum Keys {
        static let enabled = "codexEnabled"
        static let path = "codexPath"
        static let lastUsage = "codexLastUsage"
        static let alertTracker = "codexAlertTracker"
        static let checkpoints = "codexPaceCheckpoints"
        static let restorePoints = "codexPaceRestorePoints"
    }

    static let provider = "codex"
    static let pollInterval: TimeInterval = 5 * 60
    /// Opening the menu refreshes when the numbers are older than this.
    static let refreshOnOpenAfter: TimeInterval = 60
    /// Polls keep the numbers within minutes; this old means they have been failing.
    static let staleAfter: TimeInterval = 20 * 60

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            enabled ? startPolling() : stopPolling()
        }
    }
    @Published var pathOverride: String {
        didSet {
            UserDefaults.standard.set(pathOverride, forKey: Keys.path)
            refreshPath()
        }
    }
    @Published private(set) var resolvedPath: String?
    @Published private(set) var pathResolved = false

    /// Persisted, so the menu has numbers to show at launch before the first poll returns.
    @Published private(set) var usage: CodexUsage? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(usage), forKey: Keys.lastUsage) }
    }
    /// Re-pace points and quota-credit origins, with the same rules as Claude's.
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
    @Published private(set) var now = Date()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    /// The last error was a network failure: the reading shown is merely older, not wrong.
    @Published private(set) var lastErrorIsNetwork = false

    let config = PaceConfig()
    private let notifier: Notifier
    private let strings: () -> Strings
    private let locale: () -> Locale
    private var timer: Timer?
    /// Persisted, so a relaunch does not repeat notifications that already fired.
    private var alertTracker = AlertTracker() {
        didSet {
            guard alertTracker != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(alertTracker), forKey: Keys.alertTracker)
        }
    }

    init(notifier: Notifier, strings: @escaping () -> Strings, locale: @escaping () -> Locale) {
        self.notifier = notifier
        self.strings = strings
        self.locale = locale
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        pathOverride = defaults.string(forKey: Keys.path) ?? ""
        if let data = defaults.data(forKey: Keys.lastUsage),
           let remembered = try? JSONDecoder().decode(CodexUsage?.self, from: data) {
            usage = remembered
        }
        if let data = defaults.data(forKey: Keys.alertTracker),
           let remembered = try? JSONDecoder().decode(AlertTracker.self, from: data) {
            alertTracker = remembered
        }
        checkpoints = CheckpointBook(manual: CheckpointBook.decode(defaults.data(forKey: Keys.checkpoints)),
                                     restores: CheckpointBook.decode(defaults.data(forKey: Keys.restorePoints)))
        refreshPath()
        if enabled { startPolling() }
    }

    // MARK: Locating codex

    /// True when a `codex` executable is reachable. Assumed until the lookup says otherwise, so
    /// the warning does not flash at launch.
    var codexInstalled: Bool { !pathResolved || resolvedPath != nil }

    func refreshPath() {
        Task { _ = await lookUpPath() }
    }

    private func lookUpPath() async -> String? {
        let override = pathOverride
        let path = await Task.detached(priority: .userInitiated) {
            CodexProbe.resolveCodexPath(override: override)
        }.value
        // A newer lookup for a changed override has taken over.
        guard override == pathOverride else { return resolvedPath }
        resolvedPath = path
        pathResolved = true
        return path
    }

    static let installURL = URL(string: "https://developers.openai.com/codex/cli")!

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            guard let path = await lookUpPath() else {
                let overrideSet = !pathOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                lastError = overrideSet ? strings().codexPathInvalid : strings().codexNotInstalled
                lastErrorIsNetwork = false
                return
            }
            do {
                let fresh = try await probeRetryingNetworkFailures(codexPath: path)
                checkpoints.recordCredits(from: usage?.windows ?? [], to: fresh.windows)
                usage = fresh
                lastError = nil
                lastErrorIsNetwork = false
            } catch CodexProbe.ProbeError.network {
                lastError = CodexProbe.ProbeError.network.localizedDescription
                lastErrorIsNetwork = true
            } catch {
                lastError = error.localizedDescription
                lastErrorIsNetwork = false
            }
            now = Date()
            evaluateAlerts()
        }
    }

    /// Network failures to chatgpt.com come in bursts of a few seconds to a minute, so a failed
    /// read is retried a couple of times before waiting for the next poll.
    private static let networkRetryDelays: [TimeInterval] = [10, 20]

    private func probeRetryingNetworkFailures(codexPath: String) async throws -> CodexUsage {
        for delay in Self.networkRetryDelays {
            do {
                return try await CodexProbe.run(codexPath: codexPath)
            } catch CodexProbe.ProbeError.network {
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        return try await CodexProbe.run(codexPath: codexPath)
    }

    /// Called when the menu opens: keep derived values current, and fetch if the numbers are old.
    func tick() {
        now = Date()
        evaluateAlerts()
        guard enabled else { return }
        if usage.map({ now.timeIntervalSince($0.observedAt) > Self.refreshOnOpenAfter }) ?? true {
            refresh()
        }
    }

    // MARK: Derived

    func pace(for kind: WindowKind) -> Pace? {
        usage?.window(kind).map {
            PaceCalculator.compute(window: $0, now: now, config: config, checkpoint: checkpoints.checkpoint(for: $0))
        }
    }

    // MARK: Re-pace

    func checkpointIsAutomatic(_ kind: WindowKind) -> Bool {
        checkpoints.isAutomatic(usage?.window(kind))
    }

    func canRepace(_ kind: WindowKind) -> Bool {
        CheckpointBook.canRepace(usage?.window(kind), now: now, config: config)
    }

    func repaceFromNow(_ kind: WindowKind) {
        guard let window = usage?.window(kind), canRepace(kind) else { return }
        checkpoints.repace(window, now: now)
        evaluateAlerts()
    }

    func clearCheckpoint(_ kind: WindowKind) {
        checkpoints.clear(kind)
        evaluateAlerts()
    }

    /// We have data from Codex, but this window is not in it.
    func isIdle(_ kind: WindowKind) -> Bool {
        usage != nil && usage?.window(kind) == nil
    }

    /// A network failure while a recent reading is still on screen: worth a note, not an alarm.
    /// Once the reading goes stale the error is shown as one again.
    var errorIsMinor: Bool { lastErrorIsNetwork && usage != nil && !isStale }

    var isStale: Bool {
        guard let usage else { return false }
        return now.timeIntervalSince(usage.observedAt) > Self.staleAfter
    }

    /// "Plus", "Pro", … for the header; nil when unknown.
    var planLabel: String? {
        guard let plan = usage?.planType, plan != "unknown" else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// Same form as Claude's: "5h 6% ●", compact "6%".
    func menuBarTitle(kind: WindowKind, compact: Bool) -> String {
        UsageFormatter.menuBarTitle(kind: kind, pace: pace(for: kind), stale: isStale,
                                    compact: compact, idle: isIdle(kind))
    }

    // MARK: Alerts

    /// Shares the Claude notification toggles: the user asked to hear about pace, whichever
    /// subscription it is.
    private func evaluateAlerts() {
        guard enabled else { return }
        let windows = (usage?.windows ?? []).map {
            PaceWindow.rateLimit($0, provider: Self.provider, config: config, checkpoint: checkpoints.checkpoint(for: $0))
        }
        let defaults = UserDefaults.standard
        for alert in alertTracker.evaluate(windows: windows, now: now, paceConfig: config) {
            let wanted: Bool
            switch alert.kind {
            case .overPace: wanted = defaults.bool(forKey: "notifyOverPace")
            case .runningOut: wanted = defaults.bool(forKey: "notifyRunningOut")
            case .windowReset: wanted = defaults.bool(forKey: "notifyWindowReset") && alert.rateLimitWindow == .fiveHour
            case .quotaRestored: wanted = defaults.bool(forKey: "notifyQuotaRestored")
            }
            if wanted { notifier.deliver(alert, strings: strings(), locale: locale()) }
        }
    }
}
