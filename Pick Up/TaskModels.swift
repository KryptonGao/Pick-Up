import Foundation
import SwiftData

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case startHere
    case reading
    case tasks
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startHere: "开始这里"
        case .reading: "阅读"
        case .tasks: "任务"
        case .history: "继续"
        }
    }
}

enum TaskItemStatus: String, Codable, CaseIterable {
    case active
    case paused
    case completed

    var title: String {
        switch self {
        case .active: "进行中"
        case .paused: "稍后继续"
        case .completed: "已完成"
        }
    }
}

enum TaskPlanOrigin: String, Codable {
    case local
    case ai

    var title: String { self == .ai ? "AI 生成" : "本地生成" }
}

enum TaskStepStatus: String, Codable, CaseIterable {
    case pending
    case completed
    case skipped

    var title: String {
        switch self {
        case .pending: "待进行"
        case .completed: "已完成"
        case .skipped: "已跳过"
        }
    }
}

enum FocusSessionState: String, Codable {
    case running
    case paused
    case awaitingReview
    case ended
}

enum FocusEndReason: String, Codable {
    case timeReached
    case endedEarly
    case restarted
    case stepCompleted
    case pausedForLater
}

struct TaskStepDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var action: String
    var estimatedMinutes: Int
    var materials: [String]
    var completionCriteria: String

    enum CodingKeys: String, CodingKey {
        case action, estimatedMinutes, materials, completionCriteria
    }
}

struct TaskBreakdownResult: Codable, Equatable, Sendable {
    var clarificationQuestion: String?
    var steps: [TaskStepDraft]
}

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var clarificationAnswer: String?
    var statusRawValue: String
    var planOriginRawValue: String
    var currentStepID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \TaskStep.task) var steps: [TaskStep]
    @Relationship(deleteRule: .cascade, inverse: \FocusSession.task) var sessions: [FocusSession]

    init(
        id: UUID = UUID(),
        title: String,
        clarificationAnswer: String? = nil,
        status: TaskItemStatus = .active,
        planOrigin: TaskPlanOrigin,
        steps: [TaskStep]
    ) {
        self.id = id
        self.title = title
        self.clarificationAnswer = clarificationAnswer
        self.statusRawValue = status.rawValue
        self.planOriginRawValue = planOrigin.rawValue
        self.currentStepID = steps.first?.id
        self.createdAt = .now
        self.updatedAt = .now
        self.steps = steps
        self.sessions = []
        self.completedAt = nil
        steps.forEach { $0.task = self }
    }

    var status: TaskItemStatus {
        get { TaskItemStatus(rawValue: statusRawValue) ?? .active }
        set {
            statusRawValue = newValue.rawValue
            completedAt = newValue == .completed ? (completedAt ?? .now) : nil
            updatedAt = .now
        }
    }

    var planOrigin: TaskPlanOrigin {
        TaskPlanOrigin(rawValue: planOriginRawValue) ?? .local
    }

    var orderedSteps: [TaskStep] { steps.sorted { $0.order < $1.order } }

    var currentStep: TaskStep? {
        if let currentStepID,
           let step = steps.first(where: { $0.id == currentStepID && $0.status == .pending }) {
            return step
        }
        return orderedSteps.first(where: { $0.status == .pending })
    }

    var completedStepCount: Int { steps.count(where: { $0.status == .completed }) }
}

@Model
final class TaskStep {
    @Attribute(.unique) var id: UUID
    var order: Int
    var action: String
    var estimatedMinutes: Int
    var materials: [String]
    var completionCriteria: String
    var statusRawValue: String
    var completedAt: Date?
    var task: TaskItem?

    init(
        id: UUID = UUID(),
        order: Int,
        action: String,
        estimatedMinutes: Int,
        materials: [String],
        completionCriteria: String,
        status: TaskStepStatus = .pending
    ) {
        self.id = id
        self.order = order
        self.action = action
        self.estimatedMinutes = min(max(estimatedMinutes, 1), 480)
        self.materials = materials
        self.completionCriteria = completionCriteria
        self.statusRawValue = status.rawValue
        self.completedAt = nil
    }

    var status: TaskStepStatus {
        get { TaskStepStatus(rawValue: statusRawValue) ?? .pending }
        set {
            statusRawValue = newValue.rawValue
            completedAt = newValue == .completed ? .now : nil
        }
    }
}

@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var stepID: UUID
    var targetDuration: TimeInterval
    var remainingWhenPaused: TimeInterval
    var startedAt: Date
    var endDate: Date?
    var endedAt: Date?
    var stateRawValue: String
    var endReasonRawValue: String?
    var completionNote: String
    var task: TaskItem?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        stepID: UUID,
        targetDuration: TimeInterval,
        now: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.stepID = stepID
        self.targetDuration = targetDuration
        self.remainingWhenPaused = targetDuration
        self.startedAt = now
        self.endDate = now.addingTimeInterval(targetDuration)
        self.endedAt = nil
        self.stateRawValue = FocusSessionState.running.rawValue
        self.endReasonRawValue = nil
        self.completionNote = ""
    }

    var state: FocusSessionState {
        get { FocusSessionState(rawValue: stateRawValue) ?? .ended }
        set { stateRawValue = newValue.rawValue }
    }

    var endReason: FocusEndReason? {
        get { endReasonRawValue.flatMap(FocusEndReason.init(rawValue:)) }
        set { endReasonRawValue = newValue?.rawValue }
    }

    func remaining(at date: Date) -> TimeInterval {
        switch state {
        case .running:
            max(0, endDate?.timeIntervalSince(date) ?? remainingWhenPaused)
        case .paused:
            max(0, remainingWhenPaused)
        case .awaitingReview, .ended:
            0
        }
    }
}
