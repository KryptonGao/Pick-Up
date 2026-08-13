import Combine
import Foundation
import OSLog
import SwiftUI

enum TaskWorkspaceStage: Equatable {
    case list
    case creating
    case clarifying
    case editingDraft
}

enum FocusReviewOutcome {
    case completeStep
    case keepCurrent
    case pauseTask
}

struct AISendPreview: Identifiable, Equatable {
    let id = UUID()
    let purpose: String
    let text: String
    let sourceDescription: String
    let host: String
    let model: String
}

@MainActor
final class TaskWorkspaceViewModel: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published var selectedTaskID: UUID?
    @Published var stage: TaskWorkspaceStage = .list
    @Published var taskInput = ""
    @Published var clarificationQuestion: String?
    @Published var clarificationAnswer = ""
    @Published var draftSteps: [TaskStepDraft] = []
    @Published var draftOrigin: TaskPlanOrigin = .local
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var pendingAISend: AISendPreview?
    @Published private(set) var focusSession: FocusSession?
    @Published private(set) var now: Date
    @Published var focusMinutes = 25
    @Published var customFocusMinutes = 25
    @Published var reviewNote = ""
    @Published var taskPendingDeletion: TaskItem?

    let aiSettings: AISettingsStore
    var onContinuationCardRequested: ((ContinuationCardDraft) -> Void)?

    private let repository: TaskRepositoryProtocol
    private let localBreakdown: TaskBreakdownProviding
    private let aiClient: AICompleting
    private let notifications: NotificationScheduling
    private let clock: FocusClock
    private let logger = Logger(subsystem: "space.chenkai.Pick-Up", category: "tasks")
    private var timerCancellable: AnyCancellable?
    private var requestedOrigin: TaskPlanOrigin = .local

    init(
        repository: TaskRepositoryProtocol,
        localBreakdown: TaskBreakdownProviding? = nil,
        aiClient: AICompleting,
        aiSettings: AISettingsStore,
        notifications: NotificationScheduling? = nil,
        clock: FocusClock? = nil
    ) {
        self.repository = repository
        self.localBreakdown = localBreakdown ?? LocalTaskBreakdownService()
        self.aiClient = aiClient
        self.aiSettings = aiSettings
        self.notifications = notifications ?? FocusNotificationScheduler()
        let resolvedClock = clock ?? SystemFocusClock()
        self.clock = resolvedClock
        self.now = resolvedClock.now
        reload()
        restoreFocusSession()
        startTimer()
    }

    deinit { timerCancellable?.cancel() }

    var selectedTask: TaskItem? {
        guard let selectedTaskID else { return nil }
        return tasks.first { $0.id == selectedTaskID }
    }

    var activeTasks: [TaskItem] { tasks.filter { $0.status != .completed } }
    var completedTasks: [TaskItem] { tasks.filter { $0.status == .completed } }

    var remainingSeconds: Int {
        guard let focusSession else { return 0 }
        return Int(ceil(focusSession.remaining(at: now)))
    }

    var remainingText: String {
        let seconds = max(remainingSeconds, 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var showsGentleReminder: Bool {
        focusSession?.state == .running && (1...60).contains(remainingSeconds)
    }

    var hasOpenFocus: Bool {
        guard let state = focusSession?.state else { return false }
        return state == .running || state == .paused || state == .awaitingReview
    }

    func beginCreating() {
        stage = .creating
        taskInput = ""
        clarificationQuestion = nil
        clarificationAnswer = ""
        draftSteps = []
        errorMessage = nil
    }

    func cancelCreating() {
        stage = .list
        taskInput = ""
        clarificationQuestion = nil
        clarificationAnswer = ""
        draftSteps = []
        pendingAISend = nil
        errorMessage = nil
    }

    func requestBreakdown(origin: TaskPlanOrigin) {
        let cleanTask = taskInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTask.isEmpty else {
            errorMessage = TaskBreakdownError.emptyTask.localizedDescription
            return
        }
        guard cleanTask.count <= 2_000 else {
            errorMessage = TaskBreakdownError.tooLong.localizedDescription
            return
        }
        requestedOrigin = origin
        if origin == .ai {
            do {
                let configuration = try aiSettings.configuration()
                pendingAISend = AISendPreview(
                    purpose: clarificationQuestion == nil ? "用 AI 拆解任务" : "根据澄清回答完善步骤",
                    text: aiTaskPreviewText,
                    sourceDescription: "你输入的任务和本次澄清回答",
                    host: configuration.displayHost,
                    model: configuration.model
                )
            } catch {
                errorMessage = readable(error)
            }
        } else {
            runBreakdown(origin: .local)
        }
    }

    func confirmTaskAISend() {
        pendingAISend = nil
        runBreakdown(origin: .ai)
    }

    func submitClarification() {
        requestBreakdown(origin: requestedOrigin)
    }

    func skipClarification() {
        clarificationAnswer = "暂时跳过，请给我一个容易开始的通用计划。"
        requestBreakdown(origin: requestedOrigin)
    }

    func addDraftStep() {
        draftSteps.append(TaskStepDraft(
            action: "写下下一步动作",
            estimatedMinutes: 10,
            materials: [],
            completionCriteria: "可以清楚判断这一步已经完成"
        ))
    }

    func removeDraftStep(id: UUID) {
        guard draftSteps.count > 1 else {
            errorMessage = "至少保留一个可以开始的步骤。"
            return
        }
        draftSteps.removeAll { $0.id == id }
    }

    func moveDraftSteps(from offsets: IndexSet, to destination: Int) {
        draftSteps.move(fromOffsets: offsets, toOffset: destination)
    }

    func saveDraftTask() {
        guard !draftSteps.isEmpty,
              draftSteps.allSatisfy({ !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.completionCriteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            errorMessage = "请为每个步骤填写动作和完成标准。"
            return
        }
        let steps = draftSteps.enumerated().map { index, draft in
            TaskStep(
                order: index,
                action: draft.action.trimmingCharacters(in: .whitespacesAndNewlines),
                estimatedMinutes: draft.estimatedMinutes,
                materials: draft.materials.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                completionCriteria: draft.completionCriteria.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let task = TaskItem(
            title: taskInput.trimmingCharacters(in: .whitespacesAndNewlines),
            clarificationAnswer: clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clarificationAnswer,
            planOrigin: draftOrigin,
            steps: steps
        )
        do {
            try repository.insert(task)
            reload(selecting: task.id)
            stage = .list
            taskInput = ""
            draftSteps = []
            clarificationQuestion = nil
            clarificationAnswer = ""
        } catch {
            errorMessage = "任务没有保存成功，当前步骤仍然保留在编辑器中。"
        }
    }

    func selectTask(_ task: TaskItem) {
        if let session = focusSession,
           session.state == .running,
           session.taskID != task.id {
            errorMessage = "请先暂停当前专注，再切换到其他任务。"
            return
        }
        selectedTaskID = task.id
        errorMessage = nil
    }

    func persistTaskEdits(_ task: TaskItem) {
        task.updatedAt = clock.now
        normalizeOrders(task)
        save()
    }

    func addStep(to task: TaskItem) {
        let step = TaskStep(
            order: task.steps.count,
            action: "写下下一步动作",
            estimatedMinutes: 10,
            materials: [],
            completionCriteria: "可以清楚判断这一步已经完成"
        )
        step.task = task
        task.steps.append(step)
        if task.currentStepID == nil {
            task.currentStepID = step.id
            task.status = .active
        }
        persistTaskEdits(task)
    }

    func deleteStep(_ step: TaskStep, from task: TaskItem) {
        guard task.steps.count > 1 else {
            errorMessage = "至少保留一个步骤。"
            return
        }
        if focusSession?.stepID == step.id, hasOpenFocus {
            errorMessage = "请先结束当前专注，再删除正在执行的步骤。"
            return
        }
        task.steps.removeAll { $0.id == step.id }
        if task.currentStepID == step.id { advanceCurrentStep(in: task) }
        normalizeOrders(task)
        save()
    }

    func moveSteps(in task: TaskItem, from offsets: IndexSet, to destination: Int) {
        var ordered = task.orderedSteps
        ordered.move(fromOffsets: offsets, toOffset: destination)
        ordered.enumerated().forEach { $0.element.order = $0.offset }
        task.steps = ordered
        persistTaskEdits(task)
    }

    func moveStep(_ step: TaskStep, in task: TaskItem, by offset: Int) {
        var ordered = task.orderedSteps
        guard let index = ordered.firstIndex(where: { $0.id == step.id }) else { return }
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
        ordered.enumerated().forEach { $0.element.order = $0.offset }
        task.steps = ordered
        persistTaskEdits(task)
    }

    func markCurrentStepCompleted() {
        guard let task = selectedTask, let step = task.currentStep else { return }
        if focusSession?.stepID == step.id, hasOpenFocus {
            errorMessage = "请先结束当前专注，再更新这一步。"
            return
        }
        step.status = .completed
        advanceCurrentStep(in: task)
        save()
    }

    func skipCurrentStep() {
        guard let task = selectedTask, let step = task.currentStep else { return }
        if focusSession?.stepID == step.id, hasOpenFocus {
            errorMessage = "请先结束当前专注，再跳过这一步。"
            return
        }
        step.status = .skipped
        advanceCurrentStep(in: task)
        save()
    }

    func pauseTask() {
        guard let task = selectedTask else { return }
        task.status = .paused
        if focusSession?.state == .running { pauseFocus() }
        save()
    }

    func resumeTask() {
        guard let task = selectedTask else { return }
        task.status = .active
        save()
    }

    func requestDelete(_ task: TaskItem) {
        if focusSession?.taskID == task.id, hasOpenFocus {
            errorMessage = "请先结束这个任务的专注会话，再删除任务。"
        } else {
            taskPendingDeletion = task
        }
    }

    func confirmDeleteTask() {
        guard let task = taskPendingDeletion else { return }
        do {
            try repository.delete(task)
            taskPendingDeletion = nil
            reload()
        } catch {
            errorMessage = "任务没有删除成功，请稍后重试。"
        }
    }

    func startFocus(minutes: Int) {
        guard let task = selectedTask, let step = task.currentStep else {
            errorMessage = "请先选择一个待进行的步骤。"
            return
        }
        if hasOpenFocus {
            errorMessage = "一次只进行一个专注会话。请先结束或暂停当前会话。"
            return
        }
        let safeMinutes = min(max(minutes, 1), 180)
        let session = FocusSession(
            taskID: task.id,
            stepID: step.id,
            targetDuration: TimeInterval(safeMinutes * 60),
            now: clock.now
        )
        session.task = task
        task.sessions.append(session)
        task.status = .active
        focusSession = session
        now = clock.now
        save()
        schedule(session, title: task.title)
    }

    func pauseFocus() {
        guard let session = focusSession, session.state == .running else { return }
        session.remainingWhenPaused = session.remaining(at: clock.now)
        session.endDate = nil
        session.state = .paused
        notifications.cancelFocusEnd(sessionID: session.id)
        save()
    }

    func resumeFocus() {
        guard let session = focusSession, session.state == .paused else { return }
        session.endDate = clock.now.addingTimeInterval(max(session.remainingWhenPaused, 1))
        session.state = .running
        save()
        if let task = tasks.first(where: { $0.id == session.taskID }) { schedule(session, title: task.title) }
    }

    func extendFocus(minutes: Int) {
        guard let session = focusSession else { return }
        let seconds = TimeInterval(min(max(minutes, 1), 180) * 60)
        session.targetDuration += seconds
        if session.state == .running {
            session.endDate = (session.endDate ?? clock.now).addingTimeInterval(seconds)
        } else if session.state == .paused {
            session.remainingWhenPaused += seconds
        }
        save()
        if let task = tasks.first(where: { $0.id == session.taskID }), session.state == .running {
            schedule(session, title: task.title)
        }
    }

    func restartFocus() {
        guard let session = focusSession,
              let task = tasks.first(where: { $0.id == session.taskID }) else { return }
        notifications.cancelFocusEnd(sessionID: session.id)
        session.state = .ended
        session.endReason = .restarted
        session.endedAt = clock.now
        focusSession = nil
        save()
        selectedTaskID = task.id
        startFocus(minutes: max(1, Int(session.targetDuration / 60)))
    }

    func endFocusEarly() {
        guard let session = focusSession else { return }
        session.remainingWhenPaused = session.remaining(at: clock.now)
        session.endDate = nil
        session.state = .awaitingReview
        session.endReason = .endedEarly
        session.endedAt = clock.now
        notifications.cancelFocusEnd(sessionID: session.id)
        reviewNote = ""
        save()
    }

    func finishReview(_ outcome: FocusReviewOutcome) {
        guard let session = focusSession else { return }
        let reviewedTask = tasks.first(where: { $0.id == session.taskID })
        let reviewedStep = reviewedTask?.steps.first(where: { $0.id == session.stepID })
        session.completionNote = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)
        session.state = .ended
        session.endedAt = session.endedAt ?? clock.now
        switch outcome {
        case .completeStep:
            session.endReason = .stepCompleted
            if let task = tasks.first(where: { $0.id == session.taskID }),
               let step = task.steps.first(where: { $0.id == session.stepID }) {
                selectedTaskID = task.id
                step.status = .completed
                advanceCurrentStep(in: task)
            }
        case .keepCurrent:
            session.endReason = session.endReason ?? .timeReached
        case .pauseTask:
            session.endReason = .pausedForLater
            tasks.first(where: { $0.id == session.taskID })?.status = .paused
        }
        notifications.cancelFocusEnd(sessionID: session.id)
        focusSession = nil
        let completed = session.completionNote.isEmpty
            ? (outcome == .completeStep ? (reviewedStep?.action ?? "完成了当前步骤") : "结束了这一轮专注")
            : session.completionNote
        if let reviewedTask {
            onContinuationCardRequested?(ContinuationCardDraft(
                taskID: reviewedTask.id,
                readingDocumentID: nil,
                taskTitle: reviewedTask.title,
                completedText: completed,
                blockerText: outcome == .pauseTask ? "任务已暂停；回来时可以先确认当前状态。" : "",
                nextAction: reviewedTask.currentStep?.action ?? "回顾已完成内容并决定下一步",
                sourceAppName: "",
                sourceWindowTitle: "",
                fileHint: "",
                relatedText: ""
            ))
        }
        reviewNote = ""
        save()
    }

    func requestContinuationCard() {
        guard let task = selectedTask else { return }
        onContinuationCardRequested?(ContinuationCardDraft(
            taskID: task.id,
            readingDocumentID: nil,
            taskTitle: task.title,
            completedText: task.sessions
                .filter { $0.state == .ended && !$0.completionNote.isEmpty }
                .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
                .first?.completionNote ?? "",
            blockerText: "",
            nextAction: task.currentStep?.action ?? "回顾已完成内容并决定下一步",
            sourceAppName: "",
            sourceWindowTitle: "",
            fileHint: "",
            relatedText: ""
        ))
    }

    func testAIConnection() {
        guard !aiSettings.isTesting else { return }
        do {
            let configuration = try aiSettings.configuration(requireEnabled: false)
            aiSettings.isTesting = true
            aiSettings.statusMessage = "正在测试连接…"
            Task {
                do {
                    let schema = AIOutputSchema(name: "connection_test", object: [
                        "type": "object",
                        "properties": ["status": ["type": "string"]],
                        "required": ["status"],
                        "additionalProperties": false
                    ])
                    _ = try await aiClient.complete(
                        systemPrompt: "只返回 JSON：{\"status\":\"ok\"}",
                        userPrompt: "连接测试，不包含用户内容。",
                        schema: schema,
                        configuration: configuration
                    )
                    aiSettings.statusMessage = "连接成功。"
                } catch {
                    aiSettings.statusMessage = readable(error)
                }
                aiSettings.isTesting = false
            }
        } catch {
            aiSettings.statusMessage = readable(error)
        }
    }

    private var aiTaskPreviewText: String {
        let answer = clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? taskInput : "任务：\(taskInput)\n澄清回答：\(answer)"
    }

    private func runBreakdown(origin: TaskPlanOrigin) {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        let task = taskInput
        let clarification = clarificationQuestion == nil ? nil : clarificationAnswer
        Task {
            do {
                let result: TaskBreakdownResult
                if origin == .ai {
                    let configuration = try aiSettings.configuration()
                    result = try await AIWorkflows.breakDownTask(
                        task: task,
                        clarification: clarification,
                        clarificationQuestion: clarificationQuestion,
                        client: aiClient,
                        configuration: configuration
                    )
                } else {
                    result = try await localBreakdown.breakdown(task: task, clarification: clarification)
                }
                receive(result, origin: origin)
            } catch {
                errorMessage = readable(error)
            }
            isGenerating = false
        }
    }

    private func receive(_ result: TaskBreakdownResult, origin: TaskPlanOrigin) {
        if let question = result.clarificationQuestion {
            clarificationQuestion = question
            clarificationAnswer = ""
            stage = .clarifying
        } else {
            clarificationQuestion = nil
            draftSteps = result.steps
            draftOrigin = origin
            stage = .editingDraft
        }
    }

    private func advanceCurrentStep(in task: TaskItem) {
        if let next = task.orderedSteps.first(where: { $0.status == .pending }) {
            task.currentStepID = next.id
            task.status = .active
        } else {
            task.currentStepID = nil
            task.status = .completed
        }
        task.updatedAt = clock.now
    }

    private func normalizeOrders(_ task: TaskItem) {
        task.orderedSteps.enumerated().forEach { $0.element.order = $0.offset }
    }

    private func tick() {
        now = clock.now
        guard let session = focusSession, session.state == .running, session.remaining(at: now) <= 0 else { return }
        session.remainingWhenPaused = 0
        session.endDate = nil
        session.state = .awaitingReview
        session.endReason = .timeReached
        session.endedAt = now
        reviewNote = ""
        notifications.cancelFocusEnd(sessionID: session.id)
        save()
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { @MainActor [weak self] _ in self?.tick() }
    }

    private func schedule(_ session: FocusSession, title: String) {
        guard let endDate = session.endDate else { return }
        notifications.cancelFocusEnd(sessionID: session.id)
        Task {
            _ = await notifications.requestAuthorization()
            guard focusSession?.id == session.id,
                  session.state == .running,
                  session.endDate == endDate else { return }
            notifications.scheduleFocusEnd(sessionID: session.id, title: title, endDate: endDate)
        }
    }

    private func restoreFocusSession() {
        do {
            focusSession = try repository.loadOpenSession()
            if let session = focusSession, session.state == .running {
                if session.remaining(at: clock.now) <= 0 {
                    session.state = .awaitingReview
                    session.endReason = .timeReached
                    session.endedAt = clock.now
                    session.endDate = nil
                    try repository.save()
                } else if let task = tasks.first(where: { $0.id == session.taskID }) {
                    schedule(session, title: task.title)
                }
            }
            if let taskID = focusSession?.taskID { selectedTaskID = taskID }
        } catch {
            logger.error("focus restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    func reload(selecting id: UUID? = nil) {
        do {
            tasks = try repository.loadTasks()
            selectedTaskID = id ?? selectedTaskID ?? activeTasks.first?.id ?? completedTasks.first?.id
            if selectedTaskID.flatMap({ selected in tasks.contains(where: { $0.id == selected }) }) != true {
                selectedTaskID = tasks.first?.id
            }
        } catch {
            errorMessage = "无法读取本机任务，阅读功能仍可继续使用。"
        }
    }

    func syncAfterHistoryChanged() {
        reload()
        do {
            let persistedSession = try repository.loadOpenSession()
            if focusSession?.id != persistedSession?.id {
                if let oldID = focusSession?.id { notifications.cancelFocusEnd(sessionID: oldID) }
                focusSession = persistedSession
            }
            if let taskID = focusSession?.taskID,
               tasks.contains(where: { $0.id == taskID }) {
                selectedTaskID = taskID
            }
        } catch {
            errorMessage = "本地历史已更新，但专注状态暂时无法同步。请重新打开应用。"
        }
    }

    private func save() {
        do {
            try repository.save()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                objectWillChange.send()
                tasks.sort { $0.updatedAt > $1.updatedAt }
            }
        } catch {
            errorMessage = "更改没有保存成功，请稍后重试。"
        }
    }

    private func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "暂时无法完成这个操作，请稍后重试。"
    }
}
