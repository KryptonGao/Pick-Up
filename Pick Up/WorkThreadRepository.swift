import Foundation
import SwiftData

@MainActor
protocol WorkThreadRepositoryProtocol: AnyObject {
    func loadActive() throws -> WorkThread?
    func loadAll() throws -> [WorkThread]
    func insertActive(_ thread: WorkThread) throws
    func save() throws
    func delete(_ thread: WorkThread) throws
}

@MainActor
final class WorkThreadRepository: WorkThreadRepositoryProtocol {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func loadActive() throws -> WorkThread? {
        var descriptor = FetchDescriptor<WorkThread>(
            predicate: #Predicate { $0.statusRawValue == "active" },
            sortBy: [SortDescriptor(\.lastTouchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func loadAll() throws -> [WorkThread] {
        try context.fetch(FetchDescriptor<WorkThread>(
            sortBy: [SortDescriptor(\.lastTouchedAt, order: .reverse)]
        ))
    }

    func insertActive(_ thread: WorkThread) throws {
        let existing = try context.fetch(FetchDescriptor<WorkThread>())
        existing.forEach { $0.status = .closed }
        thread.status = .active
        context.insert(thread)
        try context.save()
    }

    func save() throws { try context.save() }

    func delete(_ thread: WorkThread) throws {
        context.delete(thread)
        try context.save()
    }
}

@MainActor
final class TransientWorkThreadRepository: WorkThreadRepositoryProtocol {
    private var threads: [WorkThread] = []

    func loadActive() throws -> WorkThread? {
        threads.first { $0.status == .active }
    }

    func loadAll() throws -> [WorkThread] {
        threads.sorted { $0.lastTouchedAt > $1.lastTouchedAt }
    }

    func insertActive(_ thread: WorkThread) throws {
        threads.forEach { $0.status = .closed }
        thread.status = .active
        threads.append(thread)
    }

    func save() throws {}

    func delete(_ thread: WorkThread) throws {
        threads.removeAll { $0.id == thread.id }
    }
}
