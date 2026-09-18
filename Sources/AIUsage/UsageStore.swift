import AIUsageCore
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
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var now = Date()
    @Published private(set) var probeState: ProbeState = .idle
    @Published private(set) var hookInstalled = false
    @Published private(set) var hookError: String?

    @Published var claudePathOverride: String {
        didSet { UserDefaults.standard.set(claudePathOverride, forKey: Keys.claudePath) }
    }

    @Published var menuBarKind: WindowKind {
        didSet { UserDefaults.standard.set(menuBarKind.rawValue, forKey: Keys.menuBarKind) }
    }

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            Strings.current = strings
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
        Strings.current = Strings.forLanguage(storedLanguage.resolved)

        refreshHookState()
        reloadFromFile()
        startWatching()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
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

    // MARK: Passive source (statusline file)

    func reloadFromFile() {
        let url = HookInstaller.statuslineFileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: url),
              let parsed = try? StatuslineParser.parse(data, observedAt: mtime) else { return }
        merge(parsed)
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
    }

    // MARK: Active source (claude -p probe)

    func probe() {
        guard probeState != .running else { return }
        guard let path = resolvedClaudePath else {
            probeState = .failed(strings.probeClaudeNotFound)
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
