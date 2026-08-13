import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class Phase3ViewModel: ObservableObject {
    @Published private(set) var cards: [ContinuationCard] = []
    @Published private(set) var records: [HistoryRecord] = []
    @Published var searchText = ""
    @Published var selectedRecordID: String?
    @Published var pendingDraft: ContinuationCardDraft?
    @Published var recordPendingDeletion: HistoryRecord?
    @Published var showDeleteAllConfirmation = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    var onResumeCard: ((ContinuationCard) -> Void)?
    var onHistoryChanged: (() -> Void)?

    private let repository: Phase3RepositoryProtocol
    private let logger = Logger(subsystem: "space.chenkai.Pick-Up", category: "recovery")

    init(repository: Phase3RepositoryProtocol) {
        self.repository = repository
        reload()
    }

    var latestOpenCard: ContinuationCard? {
        cards.filter { !$0.isClosed }.max { $0.updatedAt < $1.updatedAt }
    }

    var filteredRecords: [HistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { $0.searchText.localizedStandardContains(query) }
    }

    var selectedCard: ContinuationCard? {
        guard let selectedRecordID,
              let record = records.first(where: { $0.id == selectedRecordID }),
              record.kind == .continuation else { return nil }
        return cards.first { $0.id == record.modelID }
    }

    func present(_ draft: ContinuationCardDraft) {
        pendingDraft = draft
    }

    func saveDraft(_ draft: ContinuationCardDraft) {
        let cleanTitle = draft.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNext = draft.nextAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanNext.isEmpty else {
            errorMessage = "请至少保留“正在做什么”和“下次先做什么”。"
            return
        }
        var clean = draft
        clean.taskTitle = cleanTitle
        clean.nextAction = cleanNext
        do {
            let card = ContinuationCard(draft: clean)
            try repository.insert(card)
            pendingDraft = nil
            reload(selecting: "\(HistoryRecordKind.continuation.rawValue)-\(card.id.uuidString)")
            statusMessage = "继续卡片已保存在本机。"
        } catch {
            logger.error("card save failed: \(String(describing: error), privacy: .public)")
            errorMessage = "卡片没有保存成功，编辑内容仍然保留。"
        }
    }

    func saveEdits(to card: ContinuationCard) {
        guard !card.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !card.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请至少保留“正在做什么”和“下次先做什么”。"
            return
        }
        card.updatedAt = .now
        do {
            try repository.save()
            reload(selecting: "\(HistoryRecordKind.continuation.rawValue)-\(card.id.uuidString)")
            statusMessage = "更改已保存。"
        } catch {
            errorMessage = "更改没有保存成功，卡片仍然保留在当前页面。"
        }
    }

    func close(_ card: ContinuationCard) {
        card.isClosed = true
        card.updatedAt = .now
        saveEdits(to: card)
    }

    func resume(_ card: ContinuationCard) {
        card.lastOpenedAt = .now
        card.isClosed = false
        card.updatedAt = .now
        do {
            try repository.save()
            onResumeCard?(card)
        } catch {
            errorMessage = "暂时无法恢复工作；卡片内容仍然安全保留。"
        }
    }

    func requestDelete(_ record: HistoryRecord) {
        recordPendingDeletion = record
    }

    func confirmDelete() {
        guard let record = recordPendingDeletion else { return }
        do {
            try repository.delete(kind: record.kind, id: record.modelID)
            recordPendingDeletion = nil
            reload()
            onHistoryChanged?()
            statusMessage = "已删除这条记录，其他内容没有改变。"
        } catch {
            errorMessage = "记录没有删除成功，请稍后重试。"
        }
    }

    func confirmDeleteAll() {
        do {
            try repository.deleteAllHistory()
            showDeleteAllConfirmation = false
            reload()
            onHistoryChanged?()
            statusMessage = "本地历史已全部删除。"
        } catch {
            errorMessage = "本地历史没有全部删除成功，请稍后重试。"
        }
    }

    func export(format: HistoryExportFormat, filteredOnly: Bool) {
        let selection = filteredOnly ? filteredRecords : records
        guard !selection.isEmpty else {
            errorMessage = "当前没有可以导出的记录。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pick-Up-本地历史.\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.title = "导出 \(selection.count) 条本地记录"
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try HistoryExporter.data(for: selection, format: format)
            try data.write(to: url, options: .atomic)
            statusMessage = "已导出 \(selection.count) 条记录。"
        } catch {
            errorMessage = "导出没有完成，本地记录没有改变。请选择其他位置后重试。"
        }
    }

    func reload(selecting id: String? = nil) {
        do {
            let loadedCards = try repository.loadCards()
            let tasks = try repository.loadTasks()
            let sessions = try repository.loadSessions()
            let documents = try repository.loadDocuments()
            let taskTitles = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
            cards = loadedCards
            records = (
                loadedCards.map(record(for:)) +
                tasks.map(record(for:)) +
                sessions.map { record(for: $0, taskTitle: taskTitles[$0.taskID]) } +
                documents.map(record(for:))
            ).sorted { $0.createdAt > $1.createdAt }
            if let id { selectedRecordID = id }
            if selectedRecordID.flatMap({ selected in records.contains(where: { $0.id == selected }) }) != true {
                selectedRecordID = latestOpenCard.map { "\(HistoryRecordKind.continuation.rawValue)-\($0.id.uuidString)" } ?? records.first?.id
            }
        } catch {
            logger.error("history load failed: \(String(describing: error), privacy: .public)")
            errorMessage = "无法读取本机历史；现有任务和阅读内容不会被删除。"
        }
    }

    private func record(for card: ContinuationCard) -> HistoryRecord {
        let detail = [
            "下次先做：\(card.nextAction)",
            card.completedText.isEmpty ? nil : "已经完成：\(card.completedText)",
            card.blockerText.isEmpty ? nil : "当前卡点：\(card.blockerText)",
            card.relatedText.isEmpty ? nil : "相关文本：\(card.relatedText)"
        ].compactMap { $0 }.joined(separator: "\n")
        return HistoryRecord(
            modelID: card.id,
            kind: .continuation,
            title: card.taskTitle,
            detail: detail,
            source: card.sourceDescription,
            createdAt: card.updatedAt,
            searchText: [card.completedText, card.blockerText, card.relatedText].joined(separator: "\n")
        )
    }

    private func record(for task: TaskItem) -> HistoryRecord {
        let steps = task.orderedSteps.map {
            "[\($0.status.title)] \($0.action)（约 \($0.estimatedMinutes) 分钟）\n完成标准：\($0.completionCriteria)"
        }.joined(separator: "\n")
        return HistoryRecord(
            modelID: task.id,
            kind: .task,
            title: task.title,
            detail: steps.isEmpty ? task.status.title : steps,
            createdAt: task.updatedAt,
            searchText: task.steps.flatMap { [$0.action, $0.completionCriteria] }.joined(separator: "\n")
        )
    }

    private func record(for session: FocusSession, taskTitle: String?) -> HistoryRecord {
        let minutes = max(1, Int(session.targetDuration / 60))
        return HistoryRecord(
            modelID: session.id,
            kind: .focusSession,
            title: taskTitle ?? "专注会话",
            detail: session.completionNote.isEmpty ? "计划专注 \(minutes) 分钟" : session.completionNote,
            createdAt: session.endedAt ?? session.startedAt
        )
    }

    private func record(for document: ReadingDocument) -> HistoryRecord {
        HistoryRecord(
            modelID: document.id,
            kind: .reading,
            title: document.sourceWindowTitle?.isEmpty == false ? document.sourceWindowTitle! : "来自 \(document.sourceAppName) 的文本",
            detail: document.originalText,
            source: [document.sourceAppName, document.sourceWindowTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            createdAt: document.updatedAt,
            searchText: document.originalText
        )
    }
}

enum HistoryExporter {
    static func data(for records: [HistoryRecord], format: HistoryExportFormat) throws -> Data {
        switch format {
        case .markdown:
            let body = records.map {
                "## \($0.kind.title)：\($0.title)\n\n- 时间：\(date($0.createdAt))\n- 来源：\($0.source)\n\n\($0.detail)"
            }.joined(separator: "\n\n---\n\n")
            return Data(("# Pick Up 本地历史\n\n" + body + "\n").utf8)
        case .plainText:
            let body = records.map {
                "[\($0.kind.title)] \($0.title)\n时间：\(date($0.createdAt))\n来源：\($0.source)\n\($0.detail)"
            }.joined(separator: "\n\n--------------------\n\n")
            return Data((body + "\n").utf8)
        case .json:
            let items = records.map {
                HistoryExportItem(type: $0.kind.rawValue, title: $0.title, detail: $0.detail, source: $0.source, createdAt: $0.createdAt)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(items)
        }
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .numeric, time: .shortened)
    }
}
