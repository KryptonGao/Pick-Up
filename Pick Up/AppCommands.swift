import AppKit
import SwiftUI

@MainActor
final class AppCommandRouter {
    static let shared = AppCommandRouter()

    private weak var viewModel: AppViewModel?

    private init() {}

    func connect(_ viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func showReading() {
        viewModel?.showReadingWorkspace()
        viewModel?.onOpenPanel?()
    }

    func showTasks() {
        viewModel?.showTasks()
    }

    func showHistory() {
        viewModel?.showHistory()
    }

    func newTask() {
        viewModel?.showTasks(createNew: true)
    }

    func captureSelection() {
        guard let viewModel else { return }
        Task { await viewModel.captureSelection() }
    }

    func captureClipboard() {
        viewModel?.captureClipboard()
    }

    func showSettings() {
        viewModel?.showSettings = true
        viewModel?.onOpenPanel?()
    }

    func toggleFloating() {
        guard let viewModel else { return }
        viewModel.setKeepPanelOnTop(!viewModel.keepPanelOnTop)
    }

    func clearReading() {
        guard viewModel?.document != nil else { return }
        viewModel?.requestClear()
        viewModel?.onOpenPanel?()
    }

    func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}

struct PickUpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建任务") {
                AppCommandRouter.shared.newTask()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("读取当前选区") {
                AppCommandRouter.shared.captureSelection()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("从剪贴板新建") {
                AppCommandRouter.shared.captureClipboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandMenu("工作台") {
            Button("阅读工作台") {
                AppCommandRouter.shared.showReading()
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("任务工作台") {
                AppCommandRouter.shared.showTasks()
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("继续与历史") {
                AppCommandRouter.shared.showHistory()
            }
            .keyboardShortcut("3", modifiers: [.command])

            Divider()

            Button("显示或隐藏侧边栏") {
                AppCommandRouter.shared.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("保持工作台在前") {
                AppCommandRouter.shared.toggleFloating()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])

            Divider()

            Button("清除当前阅读内容…") {
                AppCommandRouter.shared.clearReading()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                AppCommandRouter.shared.showSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}
