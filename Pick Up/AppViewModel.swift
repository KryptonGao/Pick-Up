import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    static let captureSelection = Self("captureSelection")
}

@MainActor
final class AppViewModel: ObservableObject {
    static let maximumCharacterCount = 100_000

    @Published var phase: AppPhase
    @Published var draft: CaptureDraft?
    @Published private(set) var document: ReadingDocument?
    @Published var readingMode: ReadingMode = .focused
    @Published var showReplaceConfirmation = false
    @Published var showClearConfirmation = false
    @Published var showSettings = false
    @Published var keepPanelOnTop = false {
        didSet { onFloatingPreferenceChanged?(keepPanelOnTop) }
    }
    @Published var workspaceMode: WorkspaceMode = .reading

    let speech: SpeechController
    let tasks: TaskWorkspaceViewModel
    let recovery: Phase3ViewModel
    let aiSettings: AISettingsStore
    let aiClient: AICompleting

    var onOpenPanel: (() -> Void)?
    var onHidePanel: (() -> Void)?
    var onFloatingPreferenceChanged: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    private let repository: ReadingRepositoryProtocol
    private let selectionCapturer: SelectionCapturing
    private let clipboardCapturer: ClipboardCapturing
    private let segmenter: TextSegmenting
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "space.chenkai.Pick-Up", category: "workflow")
    private var pendingReplacement: CaptureDraft?

    init(
        repository: ReadingRepositoryProtocol,
        selectionCapturer: SelectionCapturing,
        clipboardCapturer: ClipboardCapturing,
        segmenter: TextSegmenting,
        speech: SpeechController,
        defaults: UserDefaults,
        taskRepository: TaskRepositoryProtocol? = nil,
        aiClient: AICompleting? = nil,
        aiSettings: AISettingsStore? = nil,
        notificationScheduler: NotificationScheduling? = nil,
        phase3Repository: Phase3RepositoryProtocol? = nil
    ) {
        self.repository = repository
        self.selectionCapturer = selectionCapturer
        self.clipboardCapturer = clipboardCapturer
        self.segmenter = segmenter
        self.speech = speech
        self.defaults = defaults
        let resolvedAIClient = aiClient ?? OpenAICompatibleClient()
        self.aiClient = resolvedAIClient
        let resolvedAISettings = aiSettings ?? AISettingsStore(
            defaults: defaults,
            credentials: KeychainCredentialStore()
        )
        self.aiSettings = resolvedAISettings
        let taskViewModel = TaskWorkspaceViewModel(
            repository: taskRepository ?? TransientTaskRepository(),
            aiClient: resolvedAIClient,
            aiSettings: resolvedAISettings,
            notifications: notificationScheduler ?? FocusNotificationScheduler()
        )
        self.tasks = taskViewModel
        let recoveryViewModel = Phase3ViewModel(repository: phase3Repository ?? TransientPhase3Repository())
        self.recovery = recoveryViewModel
        let loadedDocument = try? repository.loadActive()
        self.document = loadedDocument
        self.keepPanelOnTop = defaults.bool(forKey: "keepPanelOnTop")

        if !defaults.bool(forKey: "hasCompletedOnboarding") {
            self.phase = .onboarding
        } else if loadedDocument != nil {
            self.phase = .reader
        } else {
            self.phase = .idle
        }

        taskViewModel.onContinuationCardRequested = { [weak recoveryViewModel] draft in
            recoveryViewModel?.present(draft)
        }
        recoveryViewModel.onResumeCard = { [weak self] card in
            self?.resume(card)
        }
        recoveryViewModel.onHistoryChanged = { [weak self] in
            self?.reloadLocalData()
        }
        if self.phase != .onboarding, recoveryViewModel.latestOpenCard != nil {
            self.workspaceMode = .history
        }

        KeyboardShortcuts.onKeyUp(for: .captureSelection) { [weak self] in
            Task { @MainActor in await self?.captureSelection() }
        }
    }

    convenience init(repository: ReadingRepositoryProtocol) {
        self.init(
            repository: repository,
            selectionCapturer: AccessibilitySelectionCapturer(),
            clipboardCapturer: PasteboardCaptureService(),
            segmenter: TextSegmenter(),
            speech: SpeechController(),
            defaults: .standard
        )
    }

    var hasShortcut: Bool {
        KeyboardShortcuts.getShortcut(for: .captureSelection) != nil
    }

    var isAccessibilityTrusted: Bool {
        AccessibilitySelectionCapturer.isTrusted
    }

    var currentSegment: ReadingSegment? {
        guard let document else { return nil }
        let segments = document.orderedSegments
        guard segments.indices.contains(document.currentSegmentIndex) else { return segments.first }
        return segments[document.currentSegmentIndex]
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "hasCompletedOnboarding")
        phase = document == nil ? .idle : .reader
    }

    func requestAccessibilityPermission() {
        AccessibilitySelectionCapturer.requestPermission()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func captureSelection() async {
        let source = SourceContext.currentExternalApplication()
        phase = .capturing
        let start = ContinuousClock.now

        let result = await selectionCapturer.capture(from: source)
        switch result {
        case .success(let payload):
            receive(payload)
        case .failure(.noSelection), .failure(.unsupportedApp):
            let clipboardResult = await clipboardCapturer.captureByCopying(source: source)
            receive(clipboardResult)
        case .failure(let issue):
            phase = .failure(issue)
        }

        onOpenPanel?()

        logger.info(
            "capture finished in \(start.duration(to: .now).description, privacy: .public), source=\(source.bundleIdentifier ?? "unknown", privacy: .public)"
        )
    }

    func captureClipboard() {
        let source = SourceContext.currentExternalApplication()
        phase = .capturing
        receive(clipboardCapturer.captureCurrent(source: source))
        onOpenPanel?()
    }

    func receive(_ result: CaptureResult) {
        switch result {
        case .success(let payload): receive(payload)
        case .failure(let issue): phase = .failure(issue)
        }
    }

    func receive(_ payload: CapturePayload) {
        let candidate = CaptureDraft(
            text: payload.text,
            source: payload.source,
            method: payload.method,
            wasTruncated: false
        )
        draft = candidate
        phase = payload.text.count > Self.maximumCharacterCount ? .overLimit : .preview
    }

    func acceptTruncation() {
        guard let draft else { return }
        let truncated = String(draft.text.prefix(Self.maximumCharacterCount))
        self.draft = CaptureDraft(
            text: truncated,
            source: draft.source,
            method: draft.method,
            wasTruncated: true
        )
        phase = .preview
    }

    func confirmDraft() {
        guard let draft else { return }
        if document?.hasProgressOrHighlights == true {
            pendingReplacement = draft
            showReplaceConfirmation = true
            return
        }
        persist(draft)
    }

    func confirmReplacement() {
        guard let pendingReplacement else { return }
        showReplaceConfirmation = false
        persist(pendingReplacement)
        self.pendingReplacement = nil
    }

    func cancelDraft() {
        draft = nil
        phase = document == nil ? .idle : .reader
    }

    func retryCapture() {
        Task { await captureSelection() }
    }

    func showReader() {
        workspaceMode = .reading
        phase = document == nil ? .idle : .reader
    }

    func showTasks(createNew: Bool = false) {
        workspaceMode = .tasks
        if createNew { tasks.beginCreating() }
        onOpenPanel?()
    }

    func showReadingWorkspace() {
        workspaceMode = .reading
    }

    func showHistory() {
        recovery.reload()
        workspaceMode = .history
        onOpenPanel?()
    }

    func saveReadingContinuationCard() {
        guard let document else { return }
        let segment = currentSegment
        recovery.present(ContinuationCardDraft(
            taskID: nil,
            readingDocumentID: document.id,
            taskTitle: document.sourceWindowTitle?.isEmpty == false ? document.sourceWindowTitle! : "阅读 \(document.sourceAppName) 的内容",
            completedText: "已读到第 \(min(document.currentSegmentIndex + 1, document.orderedSegments.count)) / \(document.orderedSegments.count) 段",
            blockerText: "",
            nextAction: segment.map { "继续阅读：\(String($0.text.prefix(80)))" } ?? "从上次位置继续阅读",
            sourceAppName: document.sourceAppName,
            sourceWindowTitle: document.sourceWindowTitle ?? "",
            fileHint: "",
            relatedText: segment?.text ?? ""
        ))
    }

    func resume(_ card: ContinuationCard) {
        if let taskID = card.taskID,
           let task = tasks.tasks.first(where: { $0.id == taskID }) {
            tasks.selectedTaskID = task.id
            if task.status == .paused { tasks.resumeTask() }
            workspaceMode = .tasks
        } else if let documentID = card.readingDocumentID,
                  let restored = try? repository.activate(id: documentID) {
            document = restored
            phase = .reader
            workspaceMode = .reading
        } else {
            recovery.errorMessage = "原任务或阅读记录已不存在；继续卡片内容仍然保留。"
            workspaceMode = .history
        }
    }

    func reloadLocalData() {
        document = try? repository.loadActive()
        if document == nil, workspaceMode == .reading { phase = .idle }
        tasks.syncAfterHistoryChanged()
        recovery.reload()
    }

    func newCapture() {
        phase = .idle
        draft = nil
    }

    func moveCurrentSegment(by offset: Int) {
        guard let document else { return }
        let lastIndex = max(document.segments.count - 1, 0)
        document.currentSegmentIndex = min(max(document.currentSegmentIndex + offset, 0), lastIndex)
        document.updatedAt = .now
        try? repository.save()
    }

    func selectSegment(index: Int) {
        guard let document, document.orderedSegments.indices.contains(index) else { return }
        document.currentSegmentIndex = index
        document.updatedAt = .now
        try? repository.save()
    }

    func toggleHighlight(_ segment: ReadingSegment) {
        segment.isHighlighted.toggle()
        document?.updatedAt = .now
        try? repository.save()
    }

    func requestClear() {
        showClearConfirmation = true
    }

    func confirmClear() {
        speech.stop()
        do {
            try repository.clear()
            document = nil
            draft = nil
            showClearConfirmation = false
            phase = .idle
        } catch {
            logger.error("clear failed: \(String(describing: error), privacy: .public)")
            phase = .failure(.unknown)
        }
    }

    func setKeepPanelOnTop(_ value: Bool) {
        keepPanelOnTop = value
        defaults.set(value, forKey: "keepPanelOnTop")
    }

    func handlePanelClosed() {
        speech.pause()
    }

    func hideWorkbench() {
        onHidePanel?()
    }

    func quit() {
        speech.stop()
        onQuit?()
    }

    private func persist(_ draft: CaptureDraft) {
        let segments = segmenter.segment(draft.text).map {
            ReadingSegment(
                order: $0.order,
                kind: $0.kind,
                text: $0.text,
                sourceLocation: $0.sourceLocation,
                sourceLength: $0.sourceLength
            )
        }
        let document = ReadingDocument(
            originalText: draft.text,
            source: draft.source,
            captureMethod: draft.method,
            wasTruncated: draft.wasTruncated,
            segments: segments
        )
        do {
            try repository.replace(with: document)
            self.document = document
            self.draft = nil
            phase = .reader
        } catch {
            logger.error("save failed: \(String(describing: error), privacy: .public)")
            phase = .failure(.unknown)
        }
    }
}
