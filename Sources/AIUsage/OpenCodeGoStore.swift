import AIUsageCore
import Combine
import Foundation

/// OpenCode Go subscription quota: a rolling 5-hour, a weekly and a monthly window. Reading it is
/// free, so like Codex the store polls while enabled, on the same adaptive cadence, and paces every
/// window with the same math and notifications as Claude's. The API key is kept as DeepSeek's is.
@MainActor
final class OpenCodeGoStore: ObservableObject {
    private enum Keys {
        static let enabled = "opencodeGoEnabled"
        static let lastUsage = "opencodeGoLastUsage"
        static let alertTracker = "opencodeGoAlertTracker"
        static let checkpoints = "opencodeGoPaceCheckpoints"
        static let restorePoints = "opencodeGoPaceRestorePoints"
    }

    static let provider = "opencodego"
    static let kinds: [WindowKind] = [.fiveHour, .sevenDay, .month]
    /// The API key is only ever sent to `OpenCodeGoClient.endpoint`.
    static let keyFileURL = HookInstaller.supportDir.appendingPathComponent("opencode-go.key")
    /// As Codex: nothing pushes readings in between, so this also bounds how late an alert can be.
    static let idleCap: TimeInterval = 15 * 60
    static let refreshOnOpenAfter: TimeInterval = 60
    static let staleAfter: TimeInterval = 40 * 60

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            enabled ? startPolling() : stopPolling()
        }
    }
    @Published private(set) var hasAPIKey: Bool
    /// Settings-window scratch state; see `DeepSeekStore.apiKeyDraft` for why it lives here.
    @Published var apiKeyDraft = ""
    @Published private(set) var apiKeyJustSaved = false

    /// Persisted, so the menu has numbers to show at launch before the first poll returns.
    @Published private(set) var usage: OpenCodeGoUsage? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(usage), forKey: Keys.lastUsage) }
    }
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
    @Published private(set) var lastErrorIsNetwork = false

    let config = PaceConfig()
    /// Every reading, for the panel's chart.
    let history = HistoryStore(provider: OpenCodeGoStore.provider)
    private let notifier: Notifier
    private let strings: () -> Strings
    private let locale: () -> Locale
    private var timer: Timer?
    private var lastPollAt: Date?
    private var menuOpenedAt: Date?
    private var jitter = Double.random(in: RefreshPolicy.jitter)
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
        hasAPIKey = FileManager.default.fileExists(atPath: Self.keyFileURL.path)
        if let data = defaults.data(forKey: Keys.lastUsage),
           let remembered = try? JSONDecoder().decode(OpenCodeGoUsage?.self, from: data) {
            usage = remembered
        }
        if let data = defaults.data(forKey: Keys.alertTracker),
           let remembered = try? JSONDecoder().decode(AlertTracker.self, from: data) {
            alertTracker = remembered
        }
        checkpoints = CheckpointBook(manual: CheckpointBook.decode(defaults.data(forKey: Keys.checkpoints)),
                                     restores: CheckpointBook.decode(defaults.data(forKey: Keys.restorePoints)))
        if enabled { startPolling() }
    }

    // MARK: API key (0600 file, as DeepSeek's; see docs/data-contract.md)

    func saveTypedAPIKey() {
        guard !apiKeyDraft.isEmpty else { return }
        saveAPIKey(apiKeyDraft)
        apiKeyDraft = ""
        apiKeyJustSaved = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.apiKeyJustSaved = false
        }
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try? FileManager.default.removeItem(at: Self.keyFileURL)
            } else {
                try FileManager.default.createDirectory(at: HookInstaller.supportDir, withIntermediateDirectories: true)
                try Data(trimmed.utf8).write(to: Self.keyFileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyFileURL.path)
            }
            hasAPIKey = !trimmed.isEmpty
            lastError = nil
            if hasAPIKey, enabled { refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadAPIKey() -> String? {
        guard let data = try? Data(contentsOf: Self.keyFileURL) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        refresh()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// As Codex: `RefreshPolicy`'s wait from the last poll, or just after a window's reset if sooner.
    private func scheduleNextPoll() {
        stopPolling()
        guard enabled else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        let now = Date()
        let wait = RefreshPolicy.delay(now: now, lastMenuOpenAt: menuOpenedAt, constrained: constrained,
                                       idleCap: Self.idleCap) * jitter
        let due = (lastPollAt ?? now).addingTimeInterval(wait).timeIntervalSince(now)
        let fireIn = RefreshPolicy.wait(due, wakingForResets: usage?.windows.map(\.resetsAt) ?? [], now: now)
        timer = Timer.scheduledTimer(withTimeInterval: max(fireIn, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        guard let key = loadAPIKey() else {
            lastError = strings().opencodeGoNoKey
            lastErrorIsNetwork = false
            return
        }
        isRefreshing = true
        lastPollAt = Date()
        jitter = Double.random(in: RefreshPolicy.jitter)
        Task {
            defer {
                isRefreshing = false
                scheduleNextPoll()
            }
            do {
                let fresh = try await OpenCodeGoClient.fetch(apiKey: key)
                checkpoints.recordCredits(from: usage?.windows ?? [], to: fresh.windows)
                usage = fresh
                history.record(fresh.windows)
                lastError = nil
                lastErrorIsNetwork = false
            } catch OpenCodeGoClient.ClientError.network {
                lastError = OpenCodeGoClient.ClientError.network.localizedDescription
                lastErrorIsNetwork = true
            } catch {
                lastError = error.localizedDescription
                lastErrorIsNetwork = false
            }
            now = Date()
            evaluateAlerts()
        }
    }

    /// Called when the menu opens: keep derived values current, fetch if the numbers are old, and
    /// tighten the cadence to two minutes.
    func tick() {
        now = Date()
        menuOpenedAt = now
        evaluateAlerts()
        guard enabled else { return }
        if usage.map({ now.timeIntervalSince($0.observedAt) > Self.refreshOnOpenAfter }) ?? true {
            refresh()
        } else if !isRefreshing {
            scheduleNextPoll()
        }
    }

    // MARK: Derived

    func pace(for kind: WindowKind) -> Pace? {
        usage?.window(kind).map {
            PaceCalculator.compute(window: $0, now: now, config: config, checkpoint: checkpoints.checkpoint(for: $0))
        }
    }

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

    func isIdle(_ kind: WindowKind) -> Bool {
        usage != nil && usage?.window(kind) == nil
    }

    var errorIsMinor: Bool { lastErrorIsNetwork && usage != nil && !isStale }

    var isStale: Bool {
        guard let usage else { return false }
        return now.timeIntervalSince(usage.observedAt) > Self.staleAfter
    }

    /// Same form as Claude's: "5h 6% ●", compact "6%".
    func menuBarTitle(kind: WindowKind, compact: Bool) -> String {
        UsageFormatter.menuBarTitle(kind: kind, pace: pace(for: kind), stale: isStale,
                                    compact: compact, idle: isIdle(kind))
    }

    // MARK: Alerts

    /// Shares the Claude notification toggles, as Codex does.
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
