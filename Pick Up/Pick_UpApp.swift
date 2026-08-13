import AppKit
import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct Pick_UpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            PickUpCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var windowController: WorkbenchWindowController?
    private var viewModel: AppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        NSApp.setActivationPolicy(.regular)

        do {
            let schema = Schema([
                ReadingDocument.self,
                ReadingSegment.self,
                TaskItem.self,
                TaskStep.self,
                FocusSession.self,
                ContinuationCard.self,
                WorkThread.self
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let repository = ReadingRepository(container: container)
            let taskRepository = TaskRepository(container: container)
            let phase3Repository = Phase3Repository(container: container)
            let workThreadRepository = WorkThreadRepository(container: container)
            let defaults: UserDefaults
            if isUITesting, let suite = UserDefaults(suiteName: "space.chenkai.Pick-Up.UITests") {
                suite.removePersistentDomain(forName: "space.chenkai.Pick-Up.UITests")
                KeyboardShortcuts.reset(.captureSelection)
                defaults = suite
            } else {
                defaults = .standard
            }
            if arguments.contains("--skip-onboarding") {
                defaults.set(true, forKey: "hasCompletedOnboarding")
            }
            if arguments.contains("--sample-phase3") {
                let step = TaskStep(
                    order: 0,
                    action: "打开汇报文档并补上三个结论要点",
                    estimatedMinutes: 15,
                    materials: ["汇报文档"],
                    completionCriteria: "结论页已有三个可讨论的要点"
                )
                let task = TaskItem(title: "准备产品汇报", planOrigin: .local, steps: [step])
                try taskRepository.insert(task)
                try phase3Repository.insert(ContinuationCard(draft: ContinuationCardDraft(
                    taskID: task.id,
                    readingDocumentID: nil,
                    taskTitle: task.title,
                    completedText: "已经整理完背景和数据",
                    blockerText: "还缺结论页",
                    nextAction: step.action,
                    sourceAppName: "Pages",
                    sourceWindowTitle: "产品汇报",
                    fileHint: "汇报/产品汇报.pages",
                    relatedText: ""
                )))
            }
            if arguments.contains("--sample-relay") {
                let reading = ReadingDocument(
                    originalText: "产品汇报背景\n\n市场正在从功能竞争转向场景竞争。\n\n用户真正在意的是结果，而不是功能清单。",
                    source: SourceContext(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", processIdentifier: 0, windowTitle: "产品汇报"),
                    captureMethod: .accessibility,
                    wasTruncated: false,
                    segments: TextSegmenter().segment("产品汇报背景\n\n市场正在从功能竞争转向场景竞争。\n\n用户真正在意的是结果，而不是功能清单。").map {
                        ReadingSegment(order: $0.order, kind: $0.kind, text: $0.text, sourceLocation: $0.sourceLocation, sourceLength: $0.sourceLength)
                    }
                )
                try repository.replace(with: reading)
                let step = TaskStep(
                    order: 0,
                    action: "打开文档，写出 3 条结论",
                    estimatedMinutes: 10,
                    materials: ["产品汇报文档"],
                    completionCriteria: "结论页已有三条可以讨论的要点"
                )
                let task = TaskItem(title: "准备产品汇报", planOrigin: .local, steps: [step])
                try taskRepository.insert(task)
                let card = ContinuationCard(draft: ContinuationCardDraft(
                    taskID: task.id,
                    readingDocumentID: reading.id,
                    taskTitle: task.title,
                    completedText: "整理了背景与用户问题",
                    blockerText: "还缺一个可以落到行动的结论",
                    nextAction: step.action,
                    sourceAppName: "Pages",
                    sourceWindowTitle: "产品汇报",
                    fileHint: "汇报/产品汇报.pages",
                    relatedText: reading.orderedSegments.first?.text ?? ""
                ))
                try phase3Repository.insert(card)
                let thread = WorkThread(
                    title: task.title,
                    status: .active,
                    nextAction: step.action,
                    estimatedMinutes: step.estimatedMinutes,
                    readingDocumentID: reading.id,
                    taskID: task.id,
                    continuationCardID: card.id
                )
                try workThreadRepository.insertActive(thread)
            }
            let viewModel = AppViewModel(
                repository: repository,
                selectionCapturer: AccessibilitySelectionCapturer(),
                clipboardCapturer: PasteboardCaptureService(),
                segmenter: TextSegmenter(),
                speech: SpeechController(defaults: defaults),
                defaults: defaults,
                taskRepository: taskRepository,
                aiClient: OpenAICompatibleClient(),
                aiSettings: AISettingsStore(
                    defaults: defaults,
                    credentials: KeychainCredentialStore()
                ),
                phase3Repository: phase3Repository,
                workThreadRepository: workThreadRepository
            )
            let windowController = WorkbenchWindowController(viewModel: viewModel)
            let statusController = StatusItemController(viewModel: viewModel)

            viewModel.onOpenPanel = { [weak windowController] in windowController?.show() }
            viewModel.onHidePanel = { [weak windowController] in windowController?.hide() }
            viewModel.onFloatingPreferenceChanged = { [weak windowController] value in
                windowController?.setFloating(value)
            }
            viewModel.onQuit = { NSApp.terminate(nil) }

            self.viewModel = viewModel
            self.windowController = windowController
            self.statusController = statusController
            AppCommandRouter.shared.connect(viewModel)

            windowController.setFloating(viewModel.keepPanelOnTop)
            if arguments.contains("--sample-reader") {
                viewModel.receive(
                    CapturePayload(
                        text: "# 示例阅读\n\n这是第一段中文内容。它用于验证逐段阅读。\n\nThis is a mixed English paragraph.",
                        source: SourceContext(appName: "TextEdit", bundleIdentifier: "com.apple.TextEdit", processIdentifier: 0, windowTitle: "示例文稿"),
                        method: .accessibility
                    )
                )
                viewModel.confirmDraft()
            }
            // A newly launched process always starts with a visible workbench.
            // Closing the workbench later keeps the process alive as a menu bar app.
            DispatchQueue.main.async { windowController.show() }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.speech.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.show()
        }
        return true
    }
}
