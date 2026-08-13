import Foundation
import SwiftData

@MainActor
protocol ReadingRepositoryProtocol: AnyObject {
    func loadActive() throws -> ReadingDocument?
    func activate(id: UUID) throws -> ReadingDocument?
    func replace(with document: ReadingDocument) throws
    func save() throws
    func clear() throws
}

@MainActor
final class ReadingRepository: ReadingRepositoryProtocol {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func loadActive() throws -> ReadingDocument? {
        var descriptor = FetchDescriptor<ReadingDocument>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func activate(id: UUID) throws -> ReadingDocument? {
        let documents = try context.fetch(FetchDescriptor<ReadingDocument>())
        guard let selected = documents.first(where: { $0.id == id }) else { return nil }
        documents.forEach { $0.isActive = $0.id == id }
        selected.updatedAt = .now
        try context.save()
        return selected
    }

    func replace(with document: ReadingDocument) throws {
        let existing = try context.fetch(FetchDescriptor<ReadingDocument>())
        existing.forEach { $0.isActive = false }
        document.isActive = true
        context.insert(document)
        try context.save()
    }

    func save() throws {
        try context.save()
    }

    func clear() throws {
        let existing = try context.fetch(FetchDescriptor<ReadingDocument>())
        existing.filter(\.isActive).forEach(context.delete)
        try context.save()
    }
}
