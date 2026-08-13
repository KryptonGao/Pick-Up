import Foundation
import SwiftData

@MainActor
protocol TaskRepositoryProtocol: AnyObject {
    func loadTasks() throws -> [TaskItem]
    func loadOpenSession() throws -> FocusSession?
    func insert(_ task: TaskItem) throws
    func delete(_ task: TaskItem) throws
    func save() throws
}

@MainActor
final class TaskRepository: TaskRepositoryProtocol {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func loadTasks() throws -> [TaskItem] {
        let descriptor = FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\TaskItem.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func loadOpenSession() throws -> FocusSession? {
        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { session in
                session.stateRawValue == "running" || session.stateRawValue == "paused" || session.stateRawValue == "awaitingReview"
            },
            sortBy: [SortDescriptor(\FocusSession.startedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    func insert(_ task: TaskItem) throws {
        context.insert(task)
        try context.save()
    }

    func delete(_ task: TaskItem) throws {
        context.delete(task)
        try context.save()
    }

    func save() throws {
        try context.save()
    }
}

@MainActor
final class TransientTaskRepository: TaskRepositoryProtocol {
    private var tasks: [TaskItem] = []

    func loadTasks() throws -> [TaskItem] {
        tasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadOpenSession() throws -> FocusSession? {
        tasks.flatMap(\.sessions).first {
            $0.state == .running || $0.state == .paused || $0.state == .awaitingReview
        }
    }

    func insert(_ task: TaskItem) throws { tasks.append(task) }
    func delete(_ task: TaskItem) throws { tasks.removeAll { $0.id == task.id } }
    func save() throws {}
}
