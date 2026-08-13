import Foundation
import SwiftData
import Testing
@testable import Pick_Up

@Suite("Phase 2 本地任务拆解")
@MainActor
struct LocalTaskBreakdownTests {
    private let service = LocalTaskBreakdownService()

    @Test("模糊任务最多询问一个结果问题")
    func vagueTaskAsksOneQuestion() async throws {
        let result = try await service.breakdown(task: "弄一下项目", clarification: nil)
        #expect(result.clarificationQuestion == "完成这件事后，你希望手上有什么可见结果？")
        #expect(result.steps.isEmpty)
    }

    @Test("澄清后生成三到五个完整步骤")
    func clarificationProducesSteps() async throws {
        let result = try await service.breakdown(
            task: "弄一下项目",
            clarification: "一份可以评审的项目说明"
        )
        #expect(result.clarificationQuestion == nil)
        #expect((3...5).contains(result.steps.count))
        #expect(result.steps.allSatisfy { !$0.action.isEmpty })
        #expect(result.steps.allSatisfy { (1...480).contains($0.estimatedMinutes) })
        #expect(result.steps.allSatisfy { !$0.completionCriteria.isEmpty })
    }

    @Test("明确写作任务无需额外提问")
    func concreteWritingTask() async throws {
        let result = try await service.breakdown(task: "写下周产品汇报", clarification: nil)
        #expect(result.clarificationQuestion == nil)
        #expect((3...5).contains(result.steps.count))
        #expect(result.steps.first?.action.hasPrefix("新建") == true)
    }

    @Test("输入上限不会静默截断")
    func taskLimit() async {
        await #expect(throws: TaskBreakdownError.tooLong) {
            try await service.breakdown(task: String(repeating: "任务", count: 1_001), clarification: nil)
        }
    }
}

@Suite("Phase 2 本地仓库", .serialized)
@MainActor
struct TaskRepositoryTests {
    @Test("保存多个任务并维持唯一当前步骤")
    func storesMultipleTasks() throws {
        let container = try makePhase2Container()
        let repository = TaskRepository(container: container)
        let first = makeTask(title: "写汇报")
        let second = makeTask(title: "读论文")
        try repository.insert(first)
        try repository.insert(second)

        let loaded = try repository.loadTasks()
        #expect(loaded.count == 2)
        #expect(first.currentStepID == first.orderedSteps.first?.id)
        #expect(first.currentStep != nil)

        first.currentStep?.status = .completed
        first.currentStepID = first.orderedSteps.first(where: { $0.status == .pending })?.id
        try repository.save()
        #expect(first.currentStep?.order == 1)
    }

    @Test("删除任务级联删除步骤与会话")
    func cascadeDelete() throws {
        let container = try makePhase2Container()
        let repository = TaskRepository(container: container)
        let task = makeTask(title: "待删除")
        let session = FocusSession(taskID: task.id, stepID: task.steps[0].id, targetDuration: 600)
        session.task = task
        task.sessions.append(session)
        try repository.insert(task)
        try repository.delete(task)

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskStep>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<FocusSession>()).isEmpty)
    }

    @Test("扩展 Schema 不影响已有阅读数据")
    func readingDataSurvivesExpandedSchema() throws {
        let container = try makePhase2Container()
        let readingRepository = ReadingRepository(container: container)
        let document = ReadingDocument(
            originalText: "保留的阅读内容。",
            source: .unknown,
            captureMethod: .manualClipboard,
            wasTruncated: false,
            segments: [ReadingSegment(order: 0, kind: .paragraph, text: "保留的阅读内容。", sourceLocation: 0, sourceLength: 8)]
        )
        try readingRepository.replace(with: document)
        try TaskRepository(container: container).insert(makeTask(title: "新任务"))
        #expect(try readingRepository.loadActive()?.originalText == "保留的阅读内容。")
    }
}

@Suite("BYOK 地址与结构化输出", .serialized)
@MainActor
struct BYOKClientTests {
    @Test("远程 HTTP 被拒绝且本机 HTTP 可用")
    func endpointPolicy() throws {
        #expect(throws: AIServiceError.insecureRemoteURL) {
            try AIEndpointPolicy.validate("http://example.com/v1")
        }
        #expect(try AIEndpointPolicy.validate("http://127.0.0.1:1234/v1").host == "127.0.0.1")
        #expect(try AIEndpointPolicy.validate("https://api.example.com/v1").scheme == "https")
    }

    @Test("任务 AI 严格解码三到五步")
    func taskAIValidation() async throws {
        let response = """
        {"clarificationQuestion":null,"steps":[
          {"action":"新建文档","estimatedMinutes":5,"materials":["空白文档"],"completionCriteria":"文档已创建"},
          {"action":"写下三个要点","estimatedMinutes":10,"materials":[],"completionCriteria":"有三个要点"},
          {"action":"完成第一段","estimatedMinutes":15,"materials":["要点"],"completionCriteria":"第一段可阅读"}
        ]}
        """
        let result = try await AIWorkflows.breakDownTask(
            task: "写汇报",
            clarification: nil,
            client: FixedAIClient(content: response),
            configuration: testConfiguration
        )
        #expect(result.steps.count == 3)
    }

    @Test("阅读 AI 要求问题数量和原文依据字段")
    func readingAIValidation() async throws {
        let response = """
        {"title":"理解问题","items":[
          {"heading":"核心是什么？","output":"关注下一步。","sourceQuote":"先完成下一步"},
          {"heading":"为什么？","output":"降低启动负担。","sourceQuote":"降低负担"},
          {"heading":"如何检查？","output":"看是否有可见结果。","sourceQuote":"可见结果"}
        ]}
        """
        let result = try await AIWorkflows.assistReading(
            action: .questions,
            text: "先完成下一步，降低负担，并留下可见结果。",
            client: FixedAIClient(content: response),
            configuration: testConfiguration
        )
        #expect(result.items.count == 3)
    }

    @Test("结构化输出不兼容时只降级重试一次")
    func structuredOutputFallback() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            let call = recorder.record(request)
            if call == 1 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }
            let body = "{\"choices\":[{\"message\":{\"content\":\"{\\\"status\\\":\\\"ok\\\"}\",\"refusal\":null}}]}"
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        defer { URLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
        let schema = AIOutputSchema(name: "test", object: [
            "type": "object",
            "properties": ["status": ["type": "string"]],
            "required": ["status"],
            "additionalProperties": false
        ])
        let output = try await client.complete(
            systemPrompt: "test",
            userPrompt: "test",
            schema: schema,
            configuration: testConfiguration
        )

        #expect(output.contains("ok"))
        #expect(recorder.count == 2)
        #expect(recorder.responseFormatType(at: 0) == "json_schema")
        #expect(recorder.responseFormatType(at: 1) == "json_object")
        #expect(recorder.systemPrompt(at: 1)?.contains("\"status\"") == true)
        #expect(recorder.authorizationValues.allSatisfy { $0 == "Bearer secret" })
    }

    @Test("兼容服务降级后仍能完成任务拆解")
    func compatibleJSONOutputCompletesWorkflow() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            let call = recorder.record(request)
            if call == 1 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }
            let content = #"{"clarificationQuestion":null,"steps":[{"action":"打开作业要求","estimatedMinutes":5,"materials":["作业说明"],"completionCriteria":"已找到要求"},{"action":"完成第一题","estimatedMinutes":15,"materials":["纸笔"],"completionCriteria":"第一题有答案"},{"action":"检查并保存","estimatedMinutes":5,"materials":[],"completionCriteria":"答案已保存"}]}"#
            let body = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]]
            ])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        defer { URLProtocolStub.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [URLProtocolStub.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: sessionConfiguration))
        let result = try await AIWorkflows.breakDownTask(
            task: "完成暑假作业",
            clarification: "数学作业",
            client: client,
            configuration: testConfiguration
        )

        #expect(result.steps.count == 3)
        #expect(recorder.responseFormatType(at: 1) == "json_object")
        #expect(recorder.systemPrompt(at: 1)?.contains("completionCriteria") == true)
        #expect(recorder.systemPrompt(at: 1)?.contains("\"minItems\":3") == true)
    }

    @Test("兼容服务响应格式错误会映射为可理解错误")
    func malformedProviderResponseMapsError() async {
        URLProtocolStub.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"unexpected\":true}".utf8)
            )
        }
        defer { URLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
        let schema = AIOutputSchema(name: "test", object: ["type": "object"])

        await #expect(throws: AIServiceError.invalidResponse) {
            try await client.complete(
                systemPrompt: "JSON",
                userPrompt: "test",
                schema: schema,
                configuration: testConfiguration
            )
        }
    }

    @Test("字段类型错误不会退化成未知错误")
    func workflowDecodeErrorIsSpecific() async {
        let malformed = #"{"clarificationQuestion":null,"steps":[{"action":"开始","estimatedMinutes":"十分钟","materials":[],"completionCriteria":"完成"}]}"#
        await #expect(throws: AIServiceError.invalidResponse) {
            try await AIWorkflows.breakDownTask(
                task: "开始任务",
                clarification: nil,
                client: FixedAIClient(content: malformed),
                configuration: testConfiguration
            )
        }
    }

    @Test("AI 回答澄清后不能再次追问")
    func clarificationOnlyOnce() async {
        let repeatedQuestion = #"{"clarificationQuestion":"还想先做哪一页？","steps":[]}"#
        await #expect(throws: AIServiceError.invalidResponse) {
            try await AIWorkflows.breakDownTask(
                task: "完成暑假作业",
                clarification: "先完成数学作业",
                client: FixedAIClient(content: repeatedQuestion),
                configuration: testConfiguration
            )
        }
    }

    @Test("用户确认前不会发起 AI 请求")
    func noRequestBeforeConsent() async throws {
        let suiteName = "PickUpAIConsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AISettingsStore(defaults: defaults, credentials: MemoryCredentialStore())
        settings.isEnabled = true
        settings.baseURL = "http://127.0.0.1:1234/v1"
        settings.model = "local-model"
        let client = CountingAIClient(content: """
        {"clarificationQuestion":null,"steps":[
          {"action":"新建文档","estimatedMinutes":5,"materials":[],"completionCriteria":"文档已创建"},
          {"action":"写下要点","estimatedMinutes":10,"materials":[],"completionCriteria":"已有要点"},
          {"action":"完成一段","estimatedMinutes":15,"materials":[],"completionCriteria":"一段可阅读"}
        ]}
        """)
        let viewModel = TaskWorkspaceViewModel(
            repository: TransientTaskRepository(),
            aiClient: client,
            aiSettings: settings,
            notifications: NotificationSchedulerStub()
        )
        viewModel.taskInput = "写产品汇报"
        viewModel.requestBreakdown(origin: .ai)
        let countBeforeConfirmation = await client.count
        #expect(countBeforeConfirmation == 0)
        #expect(viewModel.pendingAISend != nil)

        viewModel.confirmTaskAISend()
        for _ in 0..<20 {
            if await client.count == 1 { break }
            await Task.yield()
        }
        #expect(await client.count == 1)
    }
}

@Suite("专注会话状态", .serialized)
@MainActor
struct FocusSessionTests {
    @Test("暂停、继续和延长保持剩余时间")
    func pauseResumeExtend() async throws {
        let defaultsName = "PickUpFocusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = MemoryCredentialStore()
        let settings = AISettingsStore(defaults: defaults, credentials: credentials)
        let repository = TransientTaskRepository()
        let task = makeTask(title: "专注任务")
        try repository.insert(task)
        let clock = MutableFocusClock(now: Date(timeIntervalSince1970: 1_000))
        let notifications = NotificationSchedulerStub()
        let viewModel = TaskWorkspaceViewModel(
            repository: repository,
            aiClient: FixedAIClient(content: "{}"),
            aiSettings: settings,
            notifications: notifications,
            clock: clock
        )
        viewModel.selectedTaskID = task.id

        viewModel.startFocus(minutes: 10)
        #expect(viewModel.focusSession?.state == .running)
        clock.now = clock.now.addingTimeInterval(60)
        viewModel.pauseFocus()
        #expect(viewModel.focusSession?.state == .paused)
        #expect(Int(viewModel.focusSession?.remainingWhenPaused ?? 0) == 540)

        viewModel.extendFocus(minutes: 5)
        #expect(Int(viewModel.focusSession?.remainingWhenPaused ?? 0) == 840)
        viewModel.resumeFocus()
        #expect(viewModel.focusSession?.state == .running)
        for _ in 0..<10 where notifications.scheduledSessionIDs.isEmpty {
            await Task.yield()
        }
        #expect(notifications.scheduledSessionIDs.contains(viewModel.focusSession!.id))
    }

    @Test("结束复盘不会自动判定失败")
    func neutralReview() throws {
        let defaults = UserDefaults(suiteName: "PickUpReviewTests.\(UUID().uuidString)")!
        let settings = AISettingsStore(defaults: defaults, credentials: MemoryCredentialStore())
        let repository = TransientTaskRepository()
        let task = makeTask(title: "可暂停任务")
        try repository.insert(task)
        let viewModel = TaskWorkspaceViewModel(
            repository: repository,
            aiClient: FixedAIClient(content: "{}"),
            aiSettings: settings,
            notifications: NotificationSchedulerStub(),
            clock: MutableFocusClock(now: .now)
        )
        viewModel.selectedTaskID = task.id
        viewModel.startFocus(minutes: 10)
        viewModel.endFocusEarly()
        #expect(viewModel.focusSession?.state == .awaitingReview)
        viewModel.reviewNote = "完成了开头。"
        viewModel.finishReview(.pauseTask)
        #expect(viewModel.focusSession == nil)
        #expect(task.status == .paused)
        #expect(task.sessions.last?.completionNote == "完成了开头。")
    }
}

private let testConfiguration = AIProviderConfiguration(
    baseURL: URL(string: "https://example.com/v1")!,
    model: "test-model",
    apiKey: "secret"
)

private struct FixedAIClient: AICompleting {
    let content: String
    func complete(
        systemPrompt: String,
        userPrompt: String,
        schema: AIOutputSchema,
        configuration: AIProviderConfiguration
    ) async throws -> String { content }
}

private actor CountingAIClient: AICompleting {
    private(set) var count = 0
    let content: String
    init(content: String) { self.content = content }
    func complete(
        systemPrompt: String,
        userPrompt: String,
        schema: AIOutputSchema,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        count += 1
        return content
    }
}

@MainActor
private final class MemoryCredentialStore: CredentialStoring {
    var value: String?
    func load() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}

private final class MutableFocusClock: FocusClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

@MainActor
private final class NotificationSchedulerStub: NotificationScheduling {
    var scheduledSessionIDs: [UUID] = []
    var cancelledSessionIDs: [UUID] = []
    func requestAuthorization() async -> Bool { true }
    func scheduleFocusEnd(sessionID: UUID, title: String, endDate: Date) {
        scheduledSessionIDs.append(sessionID)
    }
    func cancelFocusEnd(sessionID: UUID) {
        cancelledSessionIDs.append(sessionID)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var authorizations: [String?] = []

    var count: Int { lock.withLock { bodies.count } }
    var authorizationValues: [String] { lock.withLock { authorizations.compactMap { $0 } } }

    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            bodies.append(requestBody(request))
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            return bodies.count
        }
    }

    func responseFormatType(at index: Int) -> String? {
        lock.withLock {
            guard bodies.indices.contains(index),
                  let object = try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any],
                  let format = object["response_format"] as? [String: Any] else { return nil }
            return format["type"] as? String
        }
    }

    func systemPrompt(at index: Int) -> String? {
        lock.withLock {
            guard bodies.indices.contains(index),
                  let object = try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]],
                  let system = messages.first(where: { $0["role"] as? String == "system" }) else { return nil }
            return system["content"] as? String
        }
    }

    private func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func makePhase2Container() throws -> ModelContainer {
    let schema = Schema([
        ReadingDocument.self,
        ReadingSegment.self,
        TaskItem.self,
        TaskStep.self,
        FocusSession.self
    ])
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
}

@MainActor
private func makeTask(title: String) -> TaskItem {
    TaskItem(
        title: title,
        planOrigin: .local,
        steps: [
            TaskStep(order: 0, action: "完成第一步", estimatedMinutes: 10, materials: [], completionCriteria: "第一步完成"),
            TaskStep(order: 1, action: "完成第二步", estimatedMinutes: 10, materials: [], completionCriteria: "第二步完成")
        ]
    )
}
