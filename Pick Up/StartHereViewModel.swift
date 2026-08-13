import Combine
import Foundation
import OSLog

@MainActor
final class StartHereViewModel: ObservableObject {
    @Published private(set) var thread: WorkThread?
    @Published var editingNextAction = false
    @Published var nextActionDraft = ""
    @Published var estimatedMinutesDraft = 10
    @Published var errorMessage: String?

    var onThreadChanged: (() -> Void)?

    private let repository: WorkThreadRepositoryProtocol
    private let logger = Logger(subsystem: "space.chenkai.Pick-Up", category: "relay")

    init(repository: WorkThreadRepositoryProtocol) {
        self.repository = repository
        reload()
    }

    func reload() {
        do {
            thread = try repository.loadActive()
            if thread != nil { prepareNextActionDraft() }
        } catch {
            logger.error("thread load failed: \(String(describing: error), privacy: .public)")
            errorMessage = "暂时无法读取上下文接力；已有任务、阅读和继续卡片不会改变。"
        }
    }

    func beginEditingNextAction() {
        prepareNextActionDraft()
        editingNextAction = true
        errorMessage = nil
    }

    func cancelEditingNextAction() {
        editingNextAction = false
        errorMessage = nil
    }

    func saveNextAction() {
        guard let thread else { return }
        let clean = nextActionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMessage = "请写一个具体动作，例如“打开文档，写出 3 条结论”。"
            return
        }
        thread.nextAction = clean
        thread.estimatedMinutes = min(max(estimatedMinutesDraft, 1), 480)
        thread.touch()
        errorMessage = nil
        do {
            try repository.save()
            editingNextAction = false
            reload()
            onThreadChanged?()
        } catch {
            logger.error("next action save failed: \(String(describing: error), privacy: .public)")
            errorMessage = "下一步没有保存成功，编辑内容仍然保留。"
        }
    }

    func updateThread(from card: ContinuationCard, estimatedMinutes: Int?, now: Date = .now) {
        do {
            let active = try repository.loadActive()
            let thread: WorkThread
            if let active {
                thread = active
            } else {
                thread = WorkThread(title: card.taskTitle, nextAction: card.nextAction, estimatedMinutes: estimatedMinutes ?? 0)
                try repository.insertActive(thread)
            }
            thread.title = card.taskTitle
            thread.nextAction = card.nextAction
            thread.taskID = card.taskID
            thread.readingDocumentID = card.readingDocumentID
            thread.continuationCardID = card.id
            if let estimatedMinutes { thread.estimatedMinutes = min(max(estimatedMinutes, 0), 480) }
            thread.status = .active
            thread.touch(now: now)
            try repository.save()
            reload()
            onThreadChanged?()
        } catch {
            logger.error("thread update failed: \(String(describing: error), privacy: .public)")
            errorMessage = "上下文接力没有更新成功；继续卡片仍然保存在本机。"
        }
    }

    func linkTaskAndReading(
        taskID: UUID,
        readingDocumentID: UUID?,
        title: String,
        nextAction: String,
        estimatedMinutes: Int?,
        now: Date = .now
    ) {
        do {
            let active = try repository.loadActive()
            let thread: WorkThread
            if let active {
                thread = active
            } else {
                thread = WorkThread(title: title, nextAction: nextAction, estimatedMinutes: estimatedMinutes ?? 0)
                try repository.insertActive(thread)
            }
            thread.title = title
            thread.taskID = taskID
            thread.readingDocumentID = readingDocumentID
            thread.nextAction = nextAction
            if let estimatedMinutes { thread.estimatedMinutes = min(max(estimatedMinutes, 0), 480) }
            thread.status = .active
            thread.touch(now: now)
            try repository.save()
            reload()
            onThreadChanged?()
        } catch {
            logger.error("thread link failed: \(String(describing: error), privacy: .public)")
            errorMessage = "任务与阅读的关联没有保存成功；任务本身仍然安全保留。"
        }
    }

    func close() {
        guard let thread else { return }
        thread.status = .closed
        thread.touch()
        do {
            try repository.save()
            reload()
            onThreadChanged?()
        } catch {
            logger.error("thread close failed: \(String(describing: error), privacy: .public)")
            errorMessage = "接力线没有关闭成功，请稍后重试。"
        }
    }

    private func prepareNextActionDraft() {
        guard let thread else { return }
        nextActionDraft = thread.nextAction
        estimatedMinutesDraft = max(thread.estimatedMinutes, 1)
    }
}
