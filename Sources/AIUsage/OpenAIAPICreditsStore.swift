import AIUsageCore
import Combine
import Darwin
import Foundation

@MainActor
final class OpenAIAPICreditsStore: ObservableObject {
    private enum Keys {
        static let enabled = "openAIAPICreditsEnabled"
        static let allowance = "openAIAPICreditAllowance"
        static let checkpoints = "openAIAPICreditCheckpoints"
    }

    private static let keyFileURL = HookInstaller.supportDir.appendingPathComponent("openai-api.key")

    static let adminKeysURL = URL(string: "https://platform.openai.com/settings/organization/admin-keys")!
    static let billingURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!

    enum Issue: Equatable {
        case keyFile
        case invalidKey
        case unauthorized
        case http(Int)
        case malformed
        case network
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            apiKeyDraft = ""
            restart()
        }
    }
    @Published var allowance: Decimal {
        didSet {
            guard allowance != oldValue else { return }
            UserDefaults.standard.set(NSDecimalNumber(decimal: allowance).stringValue, forKey: Keys.allowance)
            clearCheckpoint()
            if (oldValue > 0) != (allowance > 0) { restart() }
        }
    }
    @Published private var checkpoints: CheckpointBook {
        didSet {
            guard checkpoints != oldValue else { return }
            UserDefaults.standard.set(CheckpointBook.encode(checkpoints.manual), forKey: Keys.checkpoints)
        }
    }
    @Published var apiKeyDraft = ""
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var isRefreshing = false
    @Published private(set) var issue: Issue?
    @Published private(set) var now = Date()
    @Published private(set) var updatedAt: Date?
    @Published private var reading: Reading?
    @Published private var subscription: CodexSubscription?

    private struct Reading {
        let cycle: DateInterval
        let spend: Decimal
    }

    var spend: Decimal? {
        guard let reading, reading.cycle == cycle else { return nil }
        return reading.spend
    }

    var cycle: DateInterval? {
        OpenAIAPICredits.subscriptionCycle(containing: now, subscription: subscription)
    }

    var isRenewalEstimated: Bool {
        subscription?.activeUntil.map { $0 <= now } ?? false
    }

    var budgetWindow: UsageWindow? {
        guard allowance > 0, let spend, let cycle, let updatedAt else { return nil }
        let usedPercent = NSDecimalNumber(decimal: spend / allowance * 100).doubleValue
        guard usedPercent.isFinite else { return nil }
        return UsageWindow(kind: .month, usedPercent: usedPercent, resetsAt: cycle.end, observedAt: updatedAt)
    }

    var pace: Pace? {
        guard let window = budgetWindow, let cycle else { return nil }
        return OpenAIAPICredits.pace(for: window, cycle: cycle, now: now, checkpoint: checkpoints.checkpoint(for: window))
    }

    var canRepace: Bool { CheckpointBook.canRepace(budgetWindow, now: now) }

    func repaceFromNow() {
        now = Date()
        guard let window = budgetWindow, canRepace else { return }
        checkpoints.repace(window, now: now)
    }

    func clearCheckpoint() {
        checkpoints.clear(.month)
    }

    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var lastPollAt: Date?
    private var menuOpenedAt: Date?
    private var jitter = Double.random(in: RefreshPolicy.jitter)

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        allowance = Decimal(string: defaults.string(forKey: Keys.allowance) ?? "",
                            locale: Locale(identifier: "en_US_POSIX")) ?? 0
        checkpoints = CheckpointBook(manual: CheckpointBook.decode(defaults.data(forKey: Keys.checkpoints)))
        hasAPIKey = FileManager.default.fileExists(atPath: Self.keyFileURL.path)
        if enabled { refresh() }
    }

    func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            issue = .invalidKey
            return
        }
        do {
            try Self.writeKey(key)
        } catch {
            issue = .keyFile
            return
        }
        hasAPIKey = true
        apiKeyDraft = ""
        clearCheckpoint()
        restart()
    }

    func removeKey() {
        do {
            try FileManager.default.removeItem(at: Self.keyFileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The key was already removed.
        } catch {
            issue = .keyFile
            return
        }
        apiKeyDraft = ""
        hasAPIKey = false
        clearCheckpoint()
        restart()
    }

    private static func writeKey(_ key: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HookInstaller.supportDir, withIntermediateDirectories: true)
        let staging = HookInstaller.supportDir.appendingPathComponent(".openai-api-\(UUID().uuidString)")
        // Give the empty file owner-only permissions before writing the credential.
        guard fm.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: staging) }
        let file = try FileHandle(forWritingTo: staging)
        defer { try? file.close() }
        try file.write(contentsOf: Data(key.utf8))
        // Rename within the same directory so a refresh sees either the old key or the whole new one.
        guard rename(staging.path, keyFileURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func loadKey() -> String? {
        do {
            let key = try String(contentsOf: Self.keyFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hasAPIKey = true
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
                issue = .invalidKey
                return nil
            }
            return key
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            hasAPIKey = false
            reading = nil
            updatedAt = nil
            issue = nil
            return nil
        } catch {
            issue = .keyFile
            return nil
        }
    }

    private func restart() {
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        timer = nil
        lastPollAt = nil
        reading = nil
        updatedAt = nil
        issue = nil
        isRefreshing = false
        if enabled { refresh() }
    }

    func tick() {
        now = Date()
        menuOpenedAt = now
        guard enabled else { return }
        if spend == nil || (updatedAt.map { now.timeIntervalSince($0) > CodexStore.refreshOnOpenAfter } ?? true) {
            refresh()
        } else if !isRefreshing {
            scheduleNextPoll()
        }
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = nil
        guard enabled, hasAPIKey, allowance > 0 else { return }
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        let now = Date()
        let wait = RefreshPolicy.delay(now: now, lastMenuOpenAt: menuOpenedAt, constrained: constrained,
                                       idleCap: CodexStore.idleCap) * jitter
        let due = (lastPollAt ?? now).addingTimeInterval(wait).timeIntervalSince(now)
        let fireIn = RefreshPolicy.wait(due, wakingForResets: cycle.map { [$0.end] } ?? [], now: now)
        timer = Timer.scheduledTimer(withTimeInterval: max(fireIn, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard enabled, refreshTask == nil else { return }
        timer?.invalidate()
        timer = nil
        let requestTime = Date()
        now = requestTime

        let latestSubscription = CodexStore.readSubscription()
        if latestSubscription != subscription { subscription = latestSubscription }
        guard let key = loadKey(), allowance > 0 else { return }
        lastPollAt = requestTime
        jitter = Double.random(in: RefreshPolicy.jitter)
        let currentCycle = cycle
        if reading?.cycle != currentCycle {
            reading = nil
            updatedAt = nil
        }
        guard let currentCycle else {
            issue = nil
            scheduleNextPoll()
            return
        }

        isRefreshing = true
        issue = nil
        refreshTask = Task { [weak self] in
            do {
                let spend = try await OpenAIAPICreditsClient.fetchSpend(apiKey: key, cycle: currentCycle, now: requestTime)
                guard !Task.isCancelled, let self else { return }
                self.reading = Reading(cycle: currentCycle, spend: spend)
                self.updatedAt = Date()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.issue = Self.issue(for: error)
            }
            guard let self else { return }
            self.now = Date()
            self.refreshTask = nil
            self.isRefreshing = false
            self.scheduleNextPoll()
        }
    }

    private static func issue(for error: Error) -> Issue {
        switch error {
        case OpenAIAPICreditsClient.FetchError.http(401), OpenAIAPICreditsClient.FetchError.http(403):
            return .unauthorized
        case let OpenAIAPICreditsClient.FetchError.http(status): return .http(status)
        case OpenAIAPICreditsClient.FetchError.malformed, is DecodingError: return .malformed
        default: return .network
        }
    }
}
