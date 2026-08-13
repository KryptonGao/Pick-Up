import Foundation

enum AIWorkflows {
    static func breakDownTask(
        task: String,
        clarification: String?,
        clarificationQuestion: String? = nil,
        client: AICompleting,
        configuration: AIProviderConfiguration
    ) async throws -> TaskBreakdownResult {
        guard task.count <= 2_000 else { throw AIServiceError.inputTooLong(limit: 2_000) }
        let isFinalRequest = clarification != nil
        let schema = AIOutputSchema(
            name: isFinalRequest ? "task_steps" : "task_breakdown",
            object: isFinalRequest ? taskStepsSchema : taskSchema
        )
        let clarificationText = clarification?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt: String
        if isFinalRequest {
            userPrompt = """
            任务：\(task)
            你刚才询问：\(clarificationQuestion ?? "完成后希望得到什么结果？")
            用户回答：\(clarificationText?.isEmpty == false ? clarificationText! : "用户选择跳过")
            这是最后一次规划请求。即使回答不完整或重复原任务，也必须根据现有信息作合理假设，直接返回 3 到 5 个完整步骤，不得再次提问。
            """
        } else {
            userPrompt = """
            任务：\(task)
            用户尚未回答澄清问题。
            """
        }
        let content = try await client.complete(
            systemPrompt: """
            你帮助有注意力启动困难的中文用户把模糊目标变成可以马上执行的步骤。
            \(isFinalRequest ? "这是澄清后的最终请求：clarificationQuestion 必须为 null，禁止再次提问。" : "如果确实缺少一个会显著改变计划的信息，可以只返回一个简短的 clarificationQuestion，steps 为空。")
            生成计划时返回 3 到 5 个步骤。每步用具体动词开头，包含 1–480 分钟预计时间、简短材料列表和可核对的完成标准。
            不使用失败、懒惰、惩罚或羞辱性表达。只输出符合 JSON Schema 的 JSON。
            """,
            userPrompt: userPrompt,
            schema: schema,
            configuration: configuration
        )
        let data = try jsonData(from: content)
        let result: TaskBreakdownResult
        do {
            result = try JSONDecoder().decode(TaskBreakdownResult.self, from: data)
        } catch {
            throw AIServiceError.invalidResponse
        }
        if let question = result.clarificationQuestion, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard result.steps.isEmpty, clarificationText?.isEmpty != false else {
                throw AIServiceError.invalidResponse
            }
            return TaskBreakdownResult(clarificationQuestion: question, steps: [])
        }
        guard (3...5).contains(result.steps.count), result.steps.allSatisfy(isValid) else {
            throw AIServiceError.invalidResponse
        }
        return TaskBreakdownResult(clarificationQuestion: nil, steps: result.steps)
    }

    static func assistReading(
        action: ReadingAIAction,
        text: String,
        client: AICompleting,
        configuration: AIProviderConfiguration
    ) async throws -> ReadingAIResult {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { throw AIServiceError.invalidResponse }
        guard cleanText.count <= 20_000 else { throw AIServiceError.inputTooLong(limit: 20_000) }

        let content = try await client.complete(
            systemPrompt: """
            你为中文神经多样性用户提供低认知负担的阅读辅助。原文不可被替换或冒充。
            \(action.promptInstruction)
            sourceQuote 必须逐字复制一小段实际输入，作为结果依据。只输出符合 JSON Schema 的 JSON。
            """,
            userPrompt: "需要处理的原文：\n\(cleanText)",
            schema: AIOutputSchema(name: "reading_assistance", object: readingSchema),
            configuration: configuration
        )
        let data = try jsonData(from: content)
        let result: ReadingAIResult
        do {
            result = try JSONDecoder().decode(ReadingAIResult.self, from: data)
        } catch {
            throw AIServiceError.invalidResponse
        }
        guard !result.title.isEmpty,
              !result.items.isEmpty,
              result.items.count <= 10,
              result.items.allSatisfy({ !$0.heading.isEmpty && !$0.output.isEmpty && !$0.sourceQuote.isEmpty }) else {
            throw AIServiceError.invalidResponse
        }
        if action == .questions, !(3...5).contains(result.items.count) {
            throw AIServiceError.invalidResponse
        }
        return result
    }

    static let taskSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "clarificationQuestion": ["type": ["string", "null"]],
            "steps": [
                "type": "array",
                "minItems": 0,
                "maxItems": 5,
                "items": taskStepSchema
            ]
        ],
        "required": ["clarificationQuestion", "steps"],
        "additionalProperties": false
    ]

    static let taskStepsSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "clarificationQuestion": ["type": "null"],
            "steps": [
                "type": "array",
                "minItems": 3,
                "maxItems": 5,
                "items": taskStepSchema
            ]
        ],
        "required": ["clarificationQuestion", "steps"],
        "additionalProperties": false
    ]

    private static let taskStepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string"],
            "estimatedMinutes": ["type": "integer", "minimum": 1, "maximum": 480],
            "materials": ["type": "array", "items": ["type": "string"], "maxItems": 8],
            "completionCriteria": ["type": "string"]
        ],
        "required": ["action", "estimatedMinutes", "materials", "completionCriteria"],
        "additionalProperties": false
    ]

    static let readingSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "items": [
                "type": "array",
                "minItems": 1,
                "maxItems": 10,
                "items": [
                    "type": "object",
                    "properties": [
                        "heading": ["type": "string"],
                        "output": ["type": "string"],
                        "sourceQuote": ["type": "string"]
                    ],
                    "required": ["heading", "output", "sourceQuote"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["title", "items"],
        "additionalProperties": false
    ]

    private static func isValid(_ step: TaskStepDraft) -> Bool {
        !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...480).contains(step.estimatedMinutes) &&
        !step.completionCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func jsonData(from content: String) throws -> Data {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start <= end else {
            throw AIServiceError.invalidResponse
        }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AIServiceError.invalidResponse
        }
        return data
    }
}
