import Foundation
import SwiftData

enum HistoryRecordKind: String, CaseIterable, Codable, Identifiable {
    case continuation
    case task
    case focusSession
    case reading

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuation: "继续卡片"
        case .task: "任务"
        case .focusSession: "专注记录"
        case .reading: "保存的文本"
        }
    }

    var symbol: String {
        switch self {
        case .continuation: "arrow.uturn.forward.circle.fill"
        case .task: "checklist"
        case .focusSession: "timer"
        case .reading: "doc.text"
        }
    }
}

enum HistoryExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case plainText
    case json

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "纯文本"
        case .json: "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .json: "json"
        }
    }
}

struct ContinuationCardDraft: Identifiable, Equatable {
    let id = UUID()
    var taskID: UUID?
    var readingDocumentID: UUID?
    var taskTitle: String
    var completedText: String
    var blockerText: String
    var nextAction: String
    var sourceAppName: String
    var sourceWindowTitle: String
    var fileHint: String
    var relatedText: String
}

@Model
final class ContinuationCard {
    @Attribute(.unique) var id: UUID
    var taskID: UUID?
    var readingDocumentID: UUID?
    var taskTitle: String
    var completedText: String
    var blockerText: String
    var nextAction: String
    var sourceAppName: String
    var sourceWindowTitle: String
    var fileHint: String
    var relatedText: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var isClosed: Bool

    init(id: UUID = UUID(), draft: ContinuationCardDraft, now: Date = .now) {
        self.id = id
        taskID = draft.taskID
        readingDocumentID = draft.readingDocumentID
        taskTitle = draft.taskTitle
        completedText = draft.completedText
        blockerText = draft.blockerText
        nextAction = draft.nextAction
        sourceAppName = draft.sourceAppName
        sourceWindowTitle = draft.sourceWindowTitle
        fileHint = draft.fileHint
        relatedText = draft.relatedText
        createdAt = now
        updatedAt = now
        lastOpenedAt = nil
        isClosed = false
    }

    var sourceDescription: String {
        [sourceAppName, sourceWindowTitle, fileHint]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct HistoryRecord: Identifiable, Equatable {
    let id: String
    let modelID: UUID
    let kind: HistoryRecordKind
    let title: String
    let detail: String
    let source: String
    let createdAt: Date
    let searchText: String

    init(
        modelID: UUID,
        kind: HistoryRecordKind,
        title: String,
        detail: String,
        source: String = "本机",
        createdAt: Date,
        searchText: String = ""
    ) {
        self.id = "\(kind.rawValue)-\(modelID.uuidString)"
        self.modelID = modelID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.source = source.isEmpty ? "本机" : source
        self.createdAt = createdAt
        self.searchText = [title, detail, source, searchText].joined(separator: "\n")
    }
}

struct HistoryExportItem: Codable, Equatable {
    let type: String
    let title: String
    let detail: String
    let source: String
    let createdAt: Date
}
