import Foundation
import SwiftData

enum WorkThreadStatus: String, Codable, Sendable {
    case active
    case closed

    var title: String {
        switch self {
        case .active: "进行中"
        case .closed: "已关闭"
        }
    }
}

@Model
final class WorkThread {
    @Attribute(.unique) var id: UUID
    var title: String
    var statusRawValue: String
    var nextAction: String
    var estimatedMinutes: Int
    var readingDocumentID: UUID?
    var taskID: UUID?
    var continuationCardID: UUID?
    var createdAt: Date
    var lastTouchedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        status: WorkThreadStatus = .active,
        nextAction: String,
        estimatedMinutes: Int,
        readingDocumentID: UUID? = nil,
        taskID: UUID? = nil,
        continuationCardID: UUID? = nil,
        now: Date = .now
    ) {
        self.id = id
        self.title = title
        self.statusRawValue = status.rawValue
        self.nextAction = nextAction
        self.estimatedMinutes = min(max(estimatedMinutes, 0), 480)
        self.readingDocumentID = readingDocumentID
        self.taskID = taskID
        self.continuationCardID = continuationCardID
        self.createdAt = now
        self.lastTouchedAt = now
    }

    var status: WorkThreadStatus {
        get { WorkThreadStatus(rawValue: statusRawValue) ?? .active }
        set { statusRawValue = newValue.rawValue }
    }

    func touch(now: Date = .now) {
        lastTouchedAt = now
    }
}
