import Foundation
import SwiftData

@MainActor
protocol Phase3RepositoryProtocol: AnyObject {
    func loadCards() throws -> [ContinuationCard]
    func loadTasks() throws -> [TaskItem]
    func loadSessions() throws -> [FocusSession]
    func loadDocuments() throws -> [ReadingDocument]
    func insert(_ card: ContinuationCard) throws
    func save() throws
    func delete(kind: HistoryRecordKind, id: UUID) throws
    func deleteAllHistory() throws
}

@MainActor
final class Phase3Repository: Phase3RepositoryProtocol {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func loadCards() throws -> [ContinuationCard] {
        try context.fetch(FetchDescriptor<ContinuationCard>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func loadTasks() throws -> [TaskItem] {
        try context.fetch(FetchDescriptor<TaskItem>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func loadSessions() throws -> [FocusSession] {
        try context.fetch(FetchDescriptor<FocusSession>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))
    }

    func loadDocuments() throws -> [ReadingDocument] {
        try context.fetch(FetchDescriptor<ReadingDocument>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func insert(_ card: ContinuationCard) throws {
        context.insert(card)
        try context.save()
    }

    func save() throws { try context.save() }

    func delete(kind: HistoryRecordKind, id: UUID) throws {
        switch kind {
        case .continuation:
            try context.fetch(FetchDescriptor<ContinuationCard>()).first(where: { $0.id == id }).map(context.delete)
        case .task:
            try context.fetch(FetchDescriptor<TaskItem>()).first(where: { $0.id == id }).map(context.delete)
        case .focusSession:
            try context.fetch(FetchDescriptor<FocusSession>()).first(where: { $0.id == id }).map(context.delete)
        case .reading:
            try context.fetch(FetchDescriptor<ReadingDocument>()).first(where: { $0.id == id }).map(context.delete)
        }
        try context.save()
    }

    func deleteAllHistory() throws {
        try context.fetch(FetchDescriptor<ContinuationCard>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<TaskItem>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ReadingDocument>()).forEach(context.delete)
        try context.save()
    }
}

@MainActor
final class TransientPhase3Repository: Phase3RepositoryProtocol {
    private var cards: [ContinuationCard] = []

    func loadCards() throws -> [ContinuationCard] { cards.sorted { $0.updatedAt > $1.updatedAt } }
    func loadTasks() throws -> [TaskItem] { [] }
    func loadSessions() throws -> [FocusSession] { [] }
    func loadDocuments() throws -> [ReadingDocument] { [] }
    func insert(_ card: ContinuationCard) throws { cards.append(card) }
    func save() throws {}
    func delete(kind: HistoryRecordKind, id: UUID) throws {
        if kind == .continuation { cards.removeAll { $0.id == id } }
    }
    func deleteAllHistory() throws { cards.removeAll() }
}
