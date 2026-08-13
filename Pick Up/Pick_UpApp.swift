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
                ContinuationCard.self
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let repository = ReadingRepository(container: container)
            let taskRepository = TaskRepository(container: container)
            let phase3Repository = Phase3Repository(container: container)
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
                phase3Repository: phase3Repository
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
