import AIUsageCore
import Combine
import Foundation

/// Gemini web/app (`gemini.google.com/usage`) 5-hour and weekly quota store. Opt-in via a manually
/// pasted Cookie header saved with mode 0600, polled on the same adaptive cadence as OpenCode Go.
@MainActor
final class GeminiAppStore: ObservableObject {
    private enum Keys {
        static let enabled = "geminiAppEnabled"
        static let cookieRemovalPending = "geminiAppCookieRemovalPending"
        static let lastUsage = "geminiAppLastUsage"
        static let alertTracker = "geminiAppAlertTracker"
        static let checkpoints = "geminiAppPaceCheckpoints"
        static let restorePoints = "geminiAppPaceRestorePoints"
    }

    static let provider = "gemini"
    /// Sent only to `gemini.google.com`.
    private static let cookieFile = GeminiCookieFile(url: HookInstaller.supportDir.appendingPathComponent("gemini-app.cookie"))
    static let idleCap: TimeInterval = 15 * 60
    static let refreshOnOpenAfter: TimeInterval = 60
    static let staleAfter: TimeInterval = 40 * 60

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            enabled ? startPolling() : stopPolling()
        }
    }
    @Published private(set) var hasCookie: Bool
    @Published var cookieDraft = ""
    @Published private(set) var cookieJustSaved = false
    @Published private(set) var cookieError: String?
    @Published private var cookieRemovalPending: Bool {
        didSet { UserDefaults.standard.set(cookieRemovalPending, forKey: Keys.cookieRemovalPending) }
    }

    var canRefresh: Bool { enabled && hasCookie && !cookieRemovalPending }

    @Published private(set) var usage: GeminiAppUsage? {
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
    let history = HistoryStore(provider: "gemini-app")
    private let notifier: Notifier
    private let strings: () -> Strings
    private let locale: () -> Locale
    private var cookieSavedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
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
        let storedCookieExists = Self.cookieFile.exists
        hasCookie = storedCookieExists
        cookieRemovalPending = storedCookieExists && defaults.bool(forKey: Keys.cookieRemovalPending)
        if cookieRemovalPending { cookieError = strings().geminiAppCookieRemoveFailed }
        if let data = defaults.data(forKey: Keys.lastUsage),
           let remembered = try? JSONDecoder().decode(GeminiAppUsage?.self, from: data) {
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

    // MARK: Cookie file

    func saveTypedCookie() {
        cookieSavedTask?.cancel()
        cookieJustSaved = false
        guard let header = GeminiCookieFile.header(from: cookieDraft) else {
            cookieError = strings().geminiAppCookieInvalid
            return
        }
        do {
            try Self.cookieFile.write(header)
        } catch {
            cookieError = strings().geminiAppCookieSaveFailed
            return
        }
        hasCookie = true
        cookieRemovalPending = false
        cookieDraft = ""
        cookieError = nil
        lastError = nil
        lastErrorIsNetwork = false
        cookieJustSaved = true
        cookieSavedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.cookieJustSaved = false
        }
        startPolling()
    }

    func removeCookie() {
        cookieSavedTask?.cancel()
        cookieJustSaved = false
        // A failed deletion must keep the credential suspended, including after relaunch.
        cookieRemovalPending = true
        stopPolling()
        lastError = nil
        lastErrorIsNetwork = false
        usage = nil
        do {
            try Self.cookieFile.remove()
        } catch {
            cookieError = strings().geminiAppCookieRemoveFailed
            return
        }
        hasCookie = false
        cookieRemovalPending = false
        cookieDraft = ""
        cookieError = nil
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        refresh()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = nil
        guard canRefresh else { return }
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
        guard canRefresh, refreshTask == nil else { return }
        let cookie: String
        do {
            guard let header = try Self.cookieFile.read() else {
                lastError = strings().geminiAppCookieInvalid
                lastErrorIsNetwork = false
                return
            }
            cookie = header
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            hasCookie = false
            lastError = strings().geminiAppNoCookie
            lastErrorIsNetwork = false
            return
        } catch {
            lastError = strings().geminiAppCookieReadFailed
            lastErrorIsNetwork = false
            return
        }
        isRefreshing = true
        lastPollAt = Date()
        jitter = Double.random(in: RefreshPolicy.jitter)
        refreshTask = Task {
            defer {
                if !Task.isCancelled {
                    refreshTask = nil
                    isRefreshing = false
                    scheduleNextPoll()
                }
            }
            do {
                guard !Task.isCancelled else { return }
                let fresh = try await GeminiAppClient.fetch(cookieHeader: cookie)
                guard !Task.isCancelled else { return }
                checkpoints.recordCredits(from: usage?.windows ?? [], to: fresh.windows)
                usage = fresh
                history.record(fresh.windows)
                lastError = nil
                lastErrorIsNetwork = false
            } catch GeminiAppClient.ClientError.network {
                guard !Task.isCancelled else { return }
                lastError = GeminiAppClient.ClientError.network.localizedDescription
                lastErrorIsNetwork = true
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                lastErrorIsNetwork = false
            }
            now = Date()
            evaluateAlerts()
        }
    }

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

    func menuBarTitle(kind: WindowKind, compact: Bool) -> String {
        UsageFormatter.menuBarTitle(kind: kind, pace: pace(for: kind), stale: isStale,
                                    compact: compact, idle: isIdle(kind))
    }

    // MARK: Alerts

    private func evaluateAlerts() {
        guard canRefresh else { return }
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
