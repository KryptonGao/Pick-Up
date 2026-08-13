import Foundation
import SwiftData
import Testing
@testable import Pick_Up

@Suite("Phase 3 继续卡片与本地历史", .serialized)
@MainActor
struct Phase3RepositoryTests {
    @Test("继续卡片持久化并按更新时间排序")
    func cardsPersistAndSort() throws {
        let repository = Phase3Repository(container: try makePhase3Container())
        let first = ContinuationCard(draft: makeDraft(title: "第一项"), now: Date(timeIntervalSince1970: 100))
        let second = ContinuationCard(draft: makeDraft(title: "第二项"), now: Date(timeIntervalSince1970: 200))
        try repository.insert(first)
        try repository.insert(second)

        let loaded = try repository.loadCards()
        #expect(loaded.map(\.taskTitle) == ["第二项", "第一项"])
        #expect(loaded.allSatisfy { !$0.isClosed })
    }

    @Test("删除单条继续卡片不影响任务和阅读记录")
    func singleDeleteIsIsolated() throws {
        let container = try makePhase3Container()
        let phase3 = Phase3Repository(container: container)
        let card = ContinuationCard(draft: makeDraft(title: "可删除"))
        try phase3.insert(card)
        try TaskRepository(container: container).insert(makePhase3Task(title: "应保留"))
        try ReadingRepository(container: container).replace(with: makePhase3Document(text: "应保留的文本"))

        try phase3.delete(kind: .continuation, id: card.id)

        #expect(try phase3.loadCards().isEmpty)
        #expect(try phase3.loadTasks().count == 1)
        #expect(try phase3.loadDocuments().count == 1)
    }

    @Test("替换阅读内容会保留历史且只有一个活动文档")
    func readingHistoryAndActivation() throws {
        let container = try makePhase3Container()
        let repository = ReadingRepository(container: container)
        let first = makePhase3Document(text: "第一份")
        let second = makePhase3Document(text: "第二份")
        try repository.replace(with: first)
        try repository.replace(with: second)

        #expect(try repository.loadActive()?.id == second.id)
        let history = try Phase3Repository(container: container).loadDocuments()
        #expect(history.count == 2)
        #expect(history.count(where: \.isActive) == 1)

        #expect(try repository.activate(id: first.id)?.id == first.id)
        #expect(try repository.loadActive()?.id == first.id)
    }
}

@Suite("Phase 3 历史导出")
struct Phase3ExportTests {
    private let records = [
        HistoryRecord(
            modelID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .continuation,
            title: "写汇报",
            detail: "先补充结论页",
            source: "Pages · 产品汇报",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    ]

    @Test("Markdown 与纯文本包含类型来源和下一步")
    func textExportsContainContext() throws {
        let markdown = String(decoding: try HistoryExporter.data(for: records, format: .markdown), as: UTF8.self)
        let text = String(decoding: try HistoryExporter.data(for: records, format: .plainText), as: UTF8.self)

        #expect(markdown.contains("继续卡片：写汇报"))
        #expect(markdown.contains("Pages · 产品汇报"))
        #expect(text.contains("先补充结论页"))
    }

    @Test("JSON 可解析且日期为 ISO 8601")
    func jsonIsStructured() throws {
        let data = try HistoryExporter.data(for: records, format: .json)
        let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(value?.first?["type"] as? String == "continuation")
        #expect(value?.first?["createdAt"] as? String != nil)
    }
}

@Suite("Phase 3 恢复视图模型")
@MainActor
struct Phase3ViewModelTests {
    @Test("草稿需要用户保存才会进入历史")
    func explicitSaveOnly() {
        let repository = TransientPhase3Repository()
        let viewModel = Phase3ViewModel(repository: repository)
        let draft = makeDraft(title: "准备汇报")

        viewModel.present(draft)
        #expect(viewModel.cards.isEmpty)
        viewModel.pendingDraft = nil
        #expect(viewModel.cards.isEmpty)

        viewModel.present(draft)
        viewModel.saveDraft(draft)
        #expect(viewModel.cards.count == 1)
        #expect(viewModel.latestOpenCard?.nextAction == "打开文档写三个要点")
    }

    @Test("搜索覆盖卡片正文与来源线索")
    func searchAcrossContext() {
        let repository = TransientPhase3Repository()
        let viewModel = Phase3ViewModel(repository: repository)
        var draft = makeDraft(title: "读论文")
        draft.fileHint = "研究/注意力.pdf"
        viewModel.saveDraft(draft)

        viewModel.searchText = "注意力.pdf"
        #expect(viewModel.filteredRecords.count == 1)
        viewModel.searchText = "不存在"
        #expect(viewModel.filteredRecords.isEmpty)
    }
}

@MainActor
private func makePhase3Container() throws -> ModelContainer {
    let schema = Schema([
        ReadingDocument.self,
        ReadingSegment.self,
        TaskItem.self,
        TaskStep.self,
        FocusSession.self,
        ContinuationCard.self
    ])
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
}

private func makeDraft(title: String) -> ContinuationCardDraft {
    ContinuationCardDraft(
        taskID: nil,
        readingDocumentID: nil,
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
private func makePhase3Task(title: String) -> TaskItem {
    TaskItem(
        title: title,
        planOrigin: .local,
        steps: [TaskStep(order: 0, action: "开始", estimatedMinutes: 10, materials: [], completionCriteria: "已开始")]
    )
}

@MainActor
private func makePhase3Document(text: String) -> ReadingDocument {
    ReadingDocument(
        originalText: text,
        source: .unknown,
        captureMethod: .manualClipboard,
        wasTruncated: false,
        segments: [ReadingSegment(order: 0, kind: .paragraph, text: text, sourceLocation: 0, sourceLength: (text as NSString).length)]
    )
}
