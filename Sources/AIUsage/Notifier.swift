import AIUsageCore
import Foundation
import UserNotifications

/// Delivers `UsageAlert`s as macOS notifications. UserNotifications needs a real bundle, so a bare
/// `swift run` binary (no bundle identifier) silently does nothing.
@MainActor
final class Notifier {
    var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

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
