import AIUsageCore
import Foundation
import UserNotifications

/// Delivers `UsageAlert`s as macOS notifications. UserNotifications needs a real bundle, so a bare
/// `swift run` binary (no bundle identifier) silently does nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
        if isSupported {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// macOS suppresses banners while the posting app is frontmost (e.g. the user just pressed
    /// "Send test notification" in our Settings window). Ask for the banner anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    struct Status: Equatable {
        var denied = false
        /// Authorized, but the user set the alert style to "None": notifications only reach
        /// Notification Center and never pop up.
        var bannersOff = false
    }

    func status() async -> Status {
        guard isSupported else { return Status() }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Status(denied: settings.authorizationStatus == .denied,
                      bannersOff: settings.authorizationStatus == .authorized && settings.alertStyle == .none)
    }

    /// Deep link to this app's page in System Settings → Notifications.
    static var systemSettingsURL: URL? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    }

    /// Asks for permission the first time a notification kind is enabled. Returns whether granted.
    func requestAuthorization() async -> Bool {
        guard isSupported else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: break
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func deliver(_ alert: UsageAlert, strings: Strings, locale: Locale) {
        guard isSupported else { return }
        let content = UNMutableNotificationContent()
        let clock = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let windowName = strings.windowTitle(alert.window)
        let resetTime = alert.resetsAt.formatted(clock)
        switch alert.kind {
        case .overPace:
            content.title = strings.alertOverPaceTitle(windowName)
            content.body = strings.alertOverPaceBody(
                UsageFormatter.percent(alert.pace.usedPercent),
                UsageFormatter.signed(alert.pace.deltaPercent),
                alert.pace.projectedPercent.map(UsageFormatter.percent) ?? "—",
                resetTime)
        case .runningOut:
            content.title = strings.alertRunningOutTitle(windowName)
            let runout = alert.pace.runoutAt.map { $0.formatted(clock) } ?? "—"
            content.body = strings.alertRunningOutBody(runout, resetTime)
        case .windowReset:
            content.title = strings.alertResetTitle(windowName)
            content.body = strings.alertResetBody
        }
        content.sound = .default
        // Identifier per condition and window instance, so a duplicate replaces rather than stacks.
        let id = "\(alert.kind.rawValue)-\(alert.window.rawValue)-\(Int(alert.resetsAt.timeIntervalSince1970))"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
