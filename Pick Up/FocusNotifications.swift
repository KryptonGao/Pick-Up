import Foundation
import UserNotifications

protocol FocusClock: Sendable {
    var now: Date { get }
}

struct SystemFocusClock: FocusClock {
    var now: Date { .now }
}

@MainActor
protocol NotificationScheduling: AnyObject {
    func requestAuthorization() async -> Bool
    func scheduleFocusEnd(sessionID: UUID, title: String, endDate: Date)
    func cancelFocusEnd(sessionID: UUID)
}

@MainActor
final class FocusNotificationScheduler: NotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func scheduleFocusEnd(sessionID: UUID, title: String, endDate: Date) {
        let interval = endDate.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = "这一轮时间到了"
        content.body = "\(title)——可以完成当前步骤、继续，或稍后再回来。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier(sessionID),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        center.add(request)
    }

    func cancelFocusEnd(sessionID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(sessionID)])
    }

    private func identifier(_ sessionID: UUID) -> String {
        "space.chenkai.Pick-Up.focus.\(sessionID.uuidString)"
    }
}
