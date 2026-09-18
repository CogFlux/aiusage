import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService: no LaunchAgent plist is written, and the entry shows up in
/// System Settings → General → Login Items where the user can also remove it.
enum LoginItem {
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isSupported else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
