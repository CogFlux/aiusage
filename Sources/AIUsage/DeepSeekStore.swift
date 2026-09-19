import AIUsageCore
import Combine
import Foundation

/// DeepSeek is prepaid: the API exposes only the current balance, so this store polls it, feeds a
/// `SpendLedger`, and derives burn rate, run-out date and, if the user set one, a monthly budget
/// pace through the shared `PaceCalculator` / `AlertTracker`.
@MainActor
final class DeepSeekStore: ObservableObject {
    private enum Keys {
        static let enabled = "deepseekEnabled"
        static let monthlyBudget = "deepseekMonthlyBudget"
        static let budgetEnabled = "deepseekBudgetEnabled"
        static let lowBalance = "deepseekLowBalance"
        static let notifyLowBalance = "deepseekNotifyLowBalance"
    }

    static let windowID = "deepseek.month"
    static let pollInterval: TimeInterval = 5 * 60
    /// The API key is only ever sent to this host.
    static let keyFileURL = HookInstaller.supportDir.appendingPathComponent("deepseek.key")
    static let ledgerFileURL = HookInstaller.supportDir.appendingPathComponent("deepseek-ledger.json")

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            enabled ? startPolling() : stopPolling()
        }
    }
    @Published private(set) var hasAPIKey: Bool
    /// Monthly spend budget in the account's currency. Only paced while `budgetEnabled` is on, so
    /// the amount survives toggling the budget off and on.
    @Published var monthlyBudget: Double {
        didSet { UserDefaults.standard.set(monthlyBudget, forKey: Keys.monthlyBudget); evaluateAlerts() }
    }
    @Published var budgetEnabled: Bool {
        didSet { UserDefaults.standard.set(budgetEnabled, forKey: Keys.budgetEnabled); evaluateAlerts() }
    }
    @Published var lowBalanceThreshold: Double {
        didSet { UserDefaults.standard.set(lowBalanceThreshold, forKey: Keys.lowBalance); evaluateAlerts() }
    }
    @Published var notifyLowBalance: Bool {
        didSet {
            UserDefaults.standard.set(notifyLowBalance, forKey: Keys.notifyLowBalance)
            if notifyLowBalance { Task { _ = await notifier.requestAuthorization() } }
        }
    }

    @Published private(set) var ledger = SpendLedger()
    @Published private(set) var latest: DeepSeekClient.Balance?
    @Published private(set) var now = Date()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let notifier: Notifier
    private let strings: () -> Strings
    private let locale: () -> Locale
    private var timer: Timer?
    private var alertTracker = AlertTracker()
    private var lowBalanceFired = false

    init(notifier: Notifier, strings: @escaping () -> Strings, locale: @escaping () -> Locale) {
        self.notifier = notifier
        self.strings = strings
        self.locale = locale
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        monthlyBudget = defaults.double(forKey: Keys.monthlyBudget)
        budgetEnabled = defaults.bool(forKey: Keys.budgetEnabled)
        lowBalanceThreshold = defaults.object(forKey: Keys.lowBalance) == nil ? 10 : defaults.double(forKey: Keys.lowBalance)
        notifyLowBalance = defaults.bool(forKey: Keys.notifyLowBalance)
        hasAPIKey = FileManager.default.fileExists(atPath: Self.keyFileURL.path)
        if let data = try? Data(contentsOf: Self.ledgerFileURL),
           let saved = try? JSONDecoder().decode(SpendLedger.self, from: data) {
            ledger = saved
        }
        if enabled { startPolling() }
    }

    // MARK: API key (0600 file; see docs/data-contract.md for why not Keychain yet)

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
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isRefreshing, let key = loadAPIKey() else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                let balance = try await DeepSeekClient.fetchBalance(apiKey: key)
                latest = balance
                now = Date()
                ledger.record(balance: balance.total, at: now)
                ledger.prune(before: now.addingTimeInterval(-90 * 86400))
                persistLedger()
                lastError = nil
                evaluateAlerts()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Time passes without a poll (menu opened); keep derived values current.
    func tick() {
        now = Date()
        evaluateAlerts()
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: Self.ledgerFileURL, options: .atomic)
        }
    }

    // MARK: Derived

    var currencyCode: String { latest?.currency ?? "CNY" }

    var monthInterval: DateInterval {
        Calendar.current.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 30 * 86400)
    }

    var spentToday: Double {
        let start = Calendar.current.startOfDay(for: now)
        return ledger.spent(from: start, to: now)
    }

    var spentThisMonth: Double { ledger.spent(from: monthInterval.start, to: now) }

    /// Trailing 7-day average, or nil with under a full day of history.
    var burnRate: SpendLedger.BurnRate? { ledger.burnRate(days: 7, now: now) }
    var burnRatePerDay: Double? { burnRate?.perDay }

    var runoutDate: Date? { ledger.runoutDate(ratePerDay: burnRatePerDay, now: now) }

    var budgetWindow: PaceWindow? {
        guard budgetEnabled, monthlyBudget > 0 else { return nil }
        let month = monthInterval
        return PaceWindow(id: Self.windowID, usedPercent: spentThisMonth / monthlyBudget * 100,
                          startsAt: month.start, resetsAt: month.end,
                          tolerance: 3, runningOutLead: 2 * 86400, minElapsed: 12 * 3600)
    }

    var budgetPace: Pace? { budgetWindow.map { PaceCalculator.compute($0, now: now) } }

    func money(_ amount: Double, compact: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currencyCode
        f.locale = locale()
        // Plain "¥"/"$" rather than the disambiguated "CN¥"/"US$" some locales produce;
        // the popover is narrow and the account has one currency anyway.
        switch currencyCode {
        case "CNY": f.currencySymbol = "¥"
        case "USD": f.currencySymbol = "$"
        default: break
        }
        f.maximumFractionDigits = compact ? 0 : 2
        f.minimumFractionDigits = compact ? 0 : 2
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    /// "DS ¥42", "DS 42% ▲6" with a budget; compact "¥42" / "42%".
    func menuBarTitle(compact: Bool) -> String {
        guard let latest else { return compact ? "—" : "DS —" }
        if let pace = budgetPace {
            let body = UsageFormatter.menuBarTitle(kind: .fiveHour, pace: pace, stale: false, compact: compact)
            return compact ? body : "DS " + body.dropFirst(3)
        }
        let amount = money(latest.total, compact: true)
        return compact ? amount : "DS " + amount
    }

    // MARK: Alerts

    private func evaluateAlerts() {
        let defaults = UserDefaults.standard
        if let window = budgetWindow {
            for alert in alertTracker.evaluate(windows: [window], now: now) {
                let enabled: Bool
                switch alert.kind {
                case .overPace: enabled = defaults.bool(forKey: "notifyOverPace")
                case .runningOut: enabled = defaults.bool(forKey: "notifyRunningOut")
                case .windowReset: enabled = false
                }
                if enabled { notifier.deliver(alert, strings: strings(), locale: locale()) }
            }
        }
        if let latest {
            let low = latest.total < lowBalanceThreshold
            if low, !lowBalanceFired, notifyLowBalance {
                lowBalanceFired = true
                notifier.deliverLowBalance(amount: money(latest.total), runout: runoutDate,
                                           strings: strings(), locale: locale())
            } else if !low {
                lowBalanceFired = false
            }
        }
    }
}
