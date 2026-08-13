import Foundation
import SwiftData
import Testing
@testable import Pick_Up

@Suite("上下文接力：工作线程仓库", .serialized)
@MainActor
struct WorkThreadRepositoryTests {
    @Test("持久化并按更新时间排序，且只允许一条 active")
    func persistAndSingleActive() throws {
        let repository = WorkThreadRepository(container: try makeRelayContainer())
        let first = WorkThread(title: "第一项", nextAction: "写第一段", estimatedMinutes: 5, now: Date(timeIntervalSince1970: 100))
        let second = WorkThread(title: "第二项", nextAction: "写第二段", estimatedMinutes: 10, now: Date(timeIntervalSince1970: 200))
        try repository.insertActive(first)
        try repository.insertActive(second)

        let all = try repository.loadAll()
        #expect(all.map(\.title) == ["第二项", "第一项"])
        #expect(try repository.loadActive()?.title == "第二项")
        #expect(all.count(where: { $0.status == .active }) == 1)
        #expect(all.count(where: { $0.status == .closed }) == 1)
    }

    @Test("删除线程不影响任务、阅读和继续卡片")
    func deleteIsIsolated() throws {
        let container = try makeRelayContainer()
        let threadRepository = WorkThreadRepository(container: container)
        let phase3 = Phase3Repository(container: container)
        let task = makeRelayTask(title: "应保留的任务")
        try TaskRepository(container: container).insert(task)
        let document = makeRelayDocument(text: "应保留的文本")
        try ReadingRepository(container: container).replace(with: document)
        let card = ContinuationCard(draft: makeRelayDraft(title: "应保留的卡片", taskID: task.id, readingDocumentID: document.id))
        try phase3.insert(card)
        let thread = WorkThread(
            title: "删除我",
            nextAction: "开始",
            estimatedMinutes: 5,
            readingDocumentID: document.id,
            taskID: task.id,
            continuationCardID: card.id
        )
        try threadRepository.insertActive(thread)

        try threadRepository.delete(thread)

        #expect(try threadRepository.loadAll().isEmpty)
        #expect(try phase3.loadTasks().count == 1)
        #expect(try phase3.loadDocuments().count == 1)
        #expect(try phase3.loadCards().count == 1)
    }
}

@Suite("上下文接力：开始这里视图模型")
@MainActor
struct StartHereViewModelTests {
    @Test("保存继续卡片后同步线程字段与关系")
    func updateThreadFromCard() throws {
        let repository = TransientWorkThreadRepository()
        let viewModel = StartHereViewModel(repository: repository)
        #expect(viewModel.thread == nil)
        let task = makeRelayTask(title: "写汇报")
        let document = makeRelayDocument(text: "背景")
        let card = ContinuationCard(draft: makeRelayDraft(title: "写汇报", taskID: task.id, readingDocumentID: document.id))

        viewModel.updateThread(from: card, estimatedMinutes: 15)

        let thread = try #require(viewModel.thread)
        #expect(thread.title == "写汇报")
        #expect(thread.taskID == task.id)
        #expect(thread.readingDocumentID == document.id)
        #expect(thread.continuationCardID == card.id)
        #expect(thread.nextAction == "打开文档写三个要点")
        #expect(thread.estimatedMinutes == 15)
        #expect(thread.status == .active)
    }

    @Test("阅读转任务保留既有继续卡片关联")
    func linkPreservesCardLink() throws {
        let repository = TransientWorkThreadRepository()
        let viewModel = StartHereViewModel(repository: repository)
        let task = makeRelayTask(title: "写汇报")
        let card = ContinuationCard(draft: makeRelayDraft(title: "写汇报", taskID: task.id, readingDocumentID: nil))
        viewModel.updateThread(from: card, estimatedMinutes: 10)
        let cardID = try #require(viewModel.thread).continuationCardID
        let document = makeRelayDocument(text: "新背景")

        viewModel.linkTaskAndReading(
            taskID: task.id,
            readingDocumentID: document.id,
            title: "新任务",
            nextAction: "开始",
            estimatedMinutes: 20
        )

        let thread = try #require(viewModel.thread)
        #expect(thread.continuationCardID == cardID)
        #expect(thread.readingDocumentID == document.id)
        #expect(thread.title == "新任务")
        #expect(thread.estimatedMinutes == 20)
        #expect(thread.status == .active)
    }

    @Test("保存下一步会拒绝空值并保存用户编辑")
    func saveNextActionValidation() throws {
        let repository = TransientWorkThreadRepository()
        let thread = WorkThread(title: "汇报", nextAction: "旧动作", estimatedMinutes: 10)
        try repository.insertActive(thread)
        let viewModel = StartHereViewModel(repository: repository)
        #expect(viewModel.thread != nil)

        viewModel.beginEditingNextAction()
        viewModel.nextActionDraft = "   "
        viewModel.saveNextAction()
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.thread?.nextAction == "旧动作")
        #expect(viewModel.editingNextAction == true)

        viewModel.nextActionDraft = "打开文档，写出 3 条结论"
        viewModel.saveNextAction()
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.thread?.nextAction == "打开文档，写出 3 条结论")
        #expect(viewModel.estimatedMinutesDraft == 10)
        #expect(viewModel.editingNextAction == false)
    }

    @Test("关闭线程不删除源记录")
    func closeKeepsSources() throws {
        let repository = TransientWorkThreadRepository()
        let viewModel = StartHereViewModel(repository: repository)
        let task = makeRelayTask(title: "汇报")
        let card = ContinuationCard(draft: makeRelayDraft(title: "汇报", taskID: task.id, readingDocumentID: nil))
        viewModel.updateThread(from: card, estimatedMinutes: 5)

        viewModel.close()

        #expect(viewModel.thread == nil)
        #expect(try repository.loadAll().first?.status == .closed)
    }
}

@Suite("上下文接力：显式接线")
@MainActor
struct ContextRelayExplicitSaveTests {
    @Test("继续卡片只有在用户保存后才触发接线")
    func cardSavedFiresOnlyAfterSave() throws {
        let repository = TransientPhase3Repository()
        let viewModel = Phase3ViewModel(repository: repository)
        var savedIDs: [UUID] = []
        viewModel.onCardSaved = { savedIDs.append($0.id) }
        let draft = makeRelayDraft(title: "汇报", taskID: nil, readingDocumentID: nil)

        viewModel.present(draft)
        viewModel.pendingDraft = nil
        #expect(savedIDs.isEmpty)

        viewModel.present(draft)
        viewModel.saveDraft(draft)
        #expect(savedIDs.count == 1)
        #expect(viewModel.cards.count == 1)
    }
}

@MainActor
private func makeRelayContainer() throws -> ModelContainer {
    let schema = Schema([
        ReadingDocument.self,
        ReadingSegment.self,
        TaskItem.self,
        TaskStep.self,
        FocusSession.self,
        ContinuationCard.self,
        WorkThread.self
    ])
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
}

private func makeRelayDraft(title: String, taskID: UUID?, readingDocumentID: UUID?) -> ContinuationCardDraft {
    ContinuationCardDraft(
        taskID: taskID,
        readingDocumentID: readingDocumentID,
        taskTitle: title,
        completedText: "已经整理背景",
        blockerText: "还缺结论",
        nextAction: "打开文档写三个要点",
        sourceAppName: "Pages",
        sourceWindowTitle: "产品汇报",
        fileHint: "",
        relatedText: ""
    )
}

@MainActor
private func makeRelayTask(title: String) -> TaskItem {
    TaskItem(
        title: title,
        planOrigin: .local,
        steps: [TaskStep(order: 0, action: "打开文档写三个要点", estimatedMinutes: 15, materials: [], completionCriteria: "结论页已有要点")]
    )
}

@MainActor
private func makeRelayDocument(text: String) -> ReadingDocument {
    ReadingDocument(
        originalText: text,
        source: .unknown,
        captureMethod: .manualClipboard,
        wasTruncated: false,
        segments: [ReadingSegment(order: 0, kind: .paragraph, text: text, sourceLocation: 0, sourceLength: (text as NSString).length)]
    )
}
