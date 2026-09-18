import Combine
import Foundation
import Sparkle

/// Thin wrapper around Sparkle. The updater only starts when the bundle's Info.plist carries
/// `SUFeedURL` and `SUPublicEDKey` (set by scripts/build-app.sh), so a bare `swift run`
/// binary and builds without a key simply run without update checks.
@MainActor
final class Updater: ObservableObject {
    let available: Bool
    @Published private(set) var canCheck = false
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Sparkle can change it on its own
    /// (its first-run permission prompt), so we observe it rather than caching the launch value.
    @Published var automaticallyChecks: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecks {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        available = info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        guard available else { return }
        controller.startUpdater()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.automaticallyChecks != value else { return }
                self.automaticallyChecks = value
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
