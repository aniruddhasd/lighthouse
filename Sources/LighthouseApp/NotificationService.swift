import AppKit
import Foundation
import UserNotifications
import LighthouseAppCore

/// Thin adapter over UNUserNotificationCenter. All the "should we notify"
/// logic lives in the pure NotificationDecider; this only requests
/// authorization, posts a decided notification, and routes a click back to
/// task selection. Safe to use even when unavailable/denied — it no-ops.
///
/// Verified 2026-07-14: UNUserNotificationCenter.current() initialises from
/// our ad-hoc-signed .app launched via `open` because Bundle.main resolves a
/// real bundle id (dev.lighthouse.app in Info.plist). It would CRASH from a
/// bare unbundled executable (no bundle id) — so this is only exercised in
/// the real .app, never in `swift test`, and the class guards on a bundle id.
@MainActor
final class NotificationService: NSObject {
    /// Routes a notification click to selecting the task.
    var onSelectTask: ((UUID) -> Void)?

    /// UNUserNotificationCenter.current() SIGTRAPs unless the app was launched
    /// by LaunchServices (open/Finder), which registers it with the
    /// notification server — a direct `exec` of the binary inside the bundle
    /// (how the gates run) is NOT registered and traps. LaunchServices injects
    /// `__CFBundleIdentifier` into the environment; its presence (plus a real
    /// bundle id) is the safe-to-touch-UN* signal (verified 2026-07-14).
    static var isLaunchedViaLaunchServices: Bool {
        Bundle.main.bundleIdentifier != nil
            && ProcessInfo.processInfo.environment["__CFBundleIdentifier"] != nil
    }
    private var center: UNUserNotificationCenter? {
        Self.isLaunchedViaLaunchServices ? UNUserNotificationCenter.current() : nil
    }
    private nonisolated static let taskIdKey = "lighthouse.taskId"

    func configure() {
        center?.delegate = self
    }

    /// Requests authorization in-context (first-run setup); returns whether
    /// it was granted. No-op (false) when unbundled.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Posts a notification for a decided kind. Returns true if the request
    /// was ENQUEUED (not whether a banner displayed — that needs the user's
    /// grant). The gate asserts on this.
    @discardableResult
    func post(kind: NotificationKind, taskId: UUID, taskName: String) -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        switch kind {
        case .needsInput:
            content.title = taskName
            content.body = "Needs your input"
            content.sound = .default
        case .done:
            content.title = taskName
            content.body = "Agent finished"
        case .sessionDied:
            content.title = taskName
            content.body = "Session ended"
        }
        content.userInfo = [Self.taskIdKey: taskId.uuidString]
        let request = UNNotificationRequest(
            identifier: "\(kind.rawValue).\(taskId.uuidString)",
            content: content, trigger: nil) // nil trigger = deliver now
        center.add(request)
        return true
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    // Show banners even while the app is active (we only post when the user
    // is NOT looking at that task, so an in-app banner is still useful).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let idString = info[NotificationService.taskIdKey] as? String
        // Complete immediately (system handler), then hop to the main actor
        // to activate + select — avoids sending the completion across actors.
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let idString, let id = UUID(uuidString: idString) {
                self.onSelectTask?(id)
            }
        }
    }
}
