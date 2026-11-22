import AIUsageCore
import Combine
import Foundation

/// Antigravity quota store: polls the local Antigravity 2.0 language server (or `agy` CLI / IDE
/// fallback) on the same adaptive cadence as Codex and paces every group's 5-hour and weekly windows.
@MainActor
final class AntigravityStore: ObservableObject {
    private enum Keys {
        static let enabled = "antigravityEnabled"
        static let agyPath = "antigravityAgyPath"
        static let lastUsage = "antigravityLastUsage"
        static let alertTracker = "antigravityAlertTracker"
        static let groupCheckpoints = "antigravityGroupCheckpoints"
        static let groupRestores = "antigravityGroupRestorePoints"
    }

    static let provider = "antigravity"
    static let idleCap: TimeInterval = 15 * 60
    static let refreshOnOpenAfter: TimeInterval = 60
    static let staleAfter: TimeInterval = 40 * 60

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            enabled ? startPolling() : stopPolling()
        }
    }
    @Published var agyPathOverride: String {
        didSet {
            UserDefaults.standard.set(agyPathOverride, forKey: Keys.agyPath)
            refreshAgyPath()
        }
    }
    @Published private(set) var resolvedAgyPath: String?

    @Published private(set) var usage: AntigravityUsage? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(usage), forKey: Keys.lastUsage) }
    }
    /// Per-group `CheckpointBook` (keyed by `group.id`, e.g. "gemini", "claude-gpt").
    @Published private(set) var checkpointsByGroup: [String: CheckpointBook] = [:] {
        didSet {
            let defaults = UserDefaults.standard
            let manual = checkpointsByGroup.mapValues(\.manual)
            let restores = checkpointsByGroup.mapValues(\.restores)
            defaults.set(try? JSONEncoder().encode(manual), forKey: Keys.groupCheckpoints)
            defaults.set(try? JSONEncoder().encode(restores), forKey: Keys.groupRestores)
        }
    }
    @Published private(set) var now = Date()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    let config = PaceConfig()
    /// Records representative (most-constrained) 5h / 7d windows for the panel's chart.
    let history = HistoryStore(provider: AntigravityStore.provider)
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
        agyPathOverride = defaults.string(forKey: Keys.agyPath) ?? ""
        if let data = defaults.data(forKey: Keys.lastUsage),
           let remembered = try? JSONDecoder().decode(AntigravityUsage?.self, from: data) {
            usage = remembered
        }
        if let data = defaults.data(forKey: Keys.alertTracker),
           let remembered = try? JSONDecoder().decode(AlertTracker.self, from: data) {
            alertTracker = remembered
        }
        let manual = defaults.data(forKey: Keys.groupCheckpoints)
            .flatMap { try? JSONDecoder().decode([String: [WindowKind: CheckpointBook.Entry]].self, from: $0) } ?? [:]
        let restores = defaults.data(forKey: Keys.groupRestores)
            .flatMap { try? JSONDecoder().decode([String: [WindowKind: CheckpointBook.Entry]].self, from: $0) } ?? [:]
        var books: [String: CheckpointBook] = [:]
        for key in Set(manual.keys).union(restores.keys) {
            books[key] = CheckpointBook(manual: manual[key] ?? [:], restores: restores[key] ?? [:])
        }
        checkpointsByGroup = books
        if enabled { startPolling() }
    }

    // MARK: Locating agy

    func refreshAgyPath() {
        Task { _ = await lookUpAgyPath() }
    }

    private func lookUpAgyPath() async -> String? {
        let override = agyPathOverride
        let path = await Task.detached(priority: .userInitiated) {
            AntigravityProbe.resolveAgyPath(override: override)
        }.value
        guard override == agyPathOverride else { return resolvedAgyPath }
        resolvedAgyPath = path
        return path
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

    private func scheduleNextPoll() {
        stopPolling()
        guard enabled else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        let now = Date()
        let wait = RefreshPolicy.delay(now: now, lastMenuOpenAt: menuOpenedAt, constrained: constrained,
                                       idleCap: Self.idleCap) * jitter
        let due = (lastPollAt ?? now).addingTimeInterval(wait).timeIntervalSince(now)
        let resets = usage?.groups.flatMap { $0.windows.map(\.resetsAt) } ?? []
        let fireIn = RefreshPolicy.wait(due, wakingForResets: resets, now: now)
        timer = Timer.scheduledTimer(withTimeInterval: max(fireIn, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastPollAt = Date()
        jitter = Double.random(in: RefreshPolicy.jitter)
        Task {
            defer {
                isRefreshing = false
                scheduleNextPoll()
            }
            let agyPath = await lookUpAgyPath()
            do {
                let fresh = try await AntigravityProbe.fetch(agyPath: agyPath)
                var updatedBooks = checkpointsByGroup
                for group in fresh.groups {
                    var book = updatedBooks[group.id] ?? CheckpointBook()
                    let oldWindows = usage?.group(group.id)?.windows ?? []
                    book.recordCredits(from: oldWindows, to: group.windows)
                    updatedBooks[group.id] = book
                }
                checkpointsByGroup = updatedBooks
                usage = fresh
                let rep = fresh.representativeWindows
                if !rep.isEmpty { history.record(rep) }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
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

    func pace(forGroup groupID: String, kind: WindowKind) -> Pace? {
        guard let window = usage?.group(groupID)?.window(kind) else { return nil }
        let cp = checkpointsByGroup[groupID]?.checkpoint(for: window)
        return PaceCalculator.compute(window: window, now: now, config: config, checkpoint: cp)
    }

    /// Most constrained pace of `kind` across all groups, for the switcher and menu bar.
    func representativePace(for kind: WindowKind) -> Pace? {
        guard let usage else { return nil }
        var best: Pace?
        for group in usage.groups {
            guard let p = pace(forGroup: group.id, kind: kind) else { continue }
            if let cur = best {
                if p.usedPercent > cur.usedPercent { best = p }
            } else {
                best = p
            }
        }
        return best
    }

    func representativeCheckpoint(for kind: WindowKind) -> PaceCheckpoint? {
        guard let usage else { return nil }
        var bestGroupID: String?
        var bestUsed: Double = -1
        for group in usage.groups {
            guard let w = group.window(kind) else { continue }
            if w.usedPercent > bestUsed {
                bestUsed = w.usedPercent
                bestGroupID = group.id
            }
        }
        guard let groupID = bestGroupID, let window = usage.group(groupID)?.window(kind) else { return nil }
        return checkpointsByGroup[groupID]?.checkpoint(for: window)
    }

    func checkpointIsAutomatic(groupID: String, kind: WindowKind) -> Bool {
        checkpointsByGroup[groupID]?.isAutomatic(usage?.group(groupID)?.window(kind)) ?? false
    }

    func canRepace(groupID: String, kind: WindowKind) -> Bool {
        CheckpointBook.canRepace(usage?.group(groupID)?.window(kind), now: now, config: config)
    }

    func repaceFromNow(groupID: String, kind: WindowKind) {
        guard let window = usage?.group(groupID)?.window(kind), canRepace(groupID: groupID, kind: kind) else { return }
        var book = checkpointsByGroup[groupID] ?? CheckpointBook()
        book.repace(window, now: now)
        checkpointsByGroup[groupID] = book
        evaluateAlerts()
    }

    func clearCheckpoint(groupID: String, kind: WindowKind) {
        var book = checkpointsByGroup[groupID] ?? CheckpointBook()
        book.clear(kind)
        checkpointsByGroup[groupID] = book
        evaluateAlerts()
    }

    var isStale: Bool {
        guard let usage else { return false }
        return now.timeIntervalSince(usage.observedAt) > Self.staleAfter
    }

    var errorIsMinor: Bool { lastError != nil && usage != nil && !isStale }

    func groupDisplayName(for groupID: String) -> String {
        if let group = usage?.group(groupID) { return group.title }
        switch groupID {
        case "gemini": return "Gemini"
        case "claude-gpt": return "Claude / GPT"
        default: return groupID
        }
    }

    func menuBarTitle(kind: WindowKind, compact: Bool) -> String {
        if let pace = representativePace(for: kind) {
            return UsageFormatter.menuBarTitle(kind: kind, pace: pace, stale: isStale, compact: compact)
        }
        // If only the other cadence exists (e.g. Starter weekly-only), fall back to it.
        let other: WindowKind = kind == .fiveHour ? .sevenDay : .fiveHour
        if let pace = representativePace(for: other) {
            return UsageFormatter.menuBarTitle(kind: other, pace: pace, stale: isStale, compact: compact)
        }
        // Legacy fallback without structured cadence: show percentage.
        if let used = usage?.fallbackUsedPercent {
            let pct = UsageFormatter.percent(used)
            let stale = isStale ? " ⧗" : ""
            return compact ? "\(pct)\(stale)" : "AG \(pct)\(stale)"
        }
        return UsageFormatter.menuBarTitle(kind: kind, pace: nil, stale: isStale, compact: compact)
    }

    // MARK: Alerts

    private func evaluateAlerts() {
        guard enabled, let usage else { return }
        var windows: [PaceWindow] = []
        for group in usage.groups {
            let book = checkpointsByGroup[group.id]
            for w in group.windows {
                let cp = book?.checkpoint(for: w)
                var pw = PaceWindow.rateLimit(w, provider: Self.provider, config: config, checkpoint: cp)
                pw.id = "\(Self.provider).\(group.id).\(w.kind.rawValue)"
                windows.append(pw)
            }
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
