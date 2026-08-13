import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkbenchWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let usesCompactTestWindow = isUITesting && arguments.contains("--compact-window")
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: usesCompactTestWindow ? 520 : 980,
            height: usesCompactTestWindow ? 532 : 720
        )
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Pick Up"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.isOpaque = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 560)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ContentView(viewModel: viewModel)
        )
        // NSHostingController may initially resize the window to the root view's
        // minimum intrinsic size. Re-apply the requested content size so compact
        // and default launch geometries remain deterministic.
        window.setContentSize(contentRect.size)
        if isUITesting {
            window.center()
        } else {
            window.setFrameAutosaveName("PickUp.WorkbenchWindow")
            if !window.setFrameUsingName("PickUp.WorkbenchWindow") {
                window.center()
            }
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
    }

    func hide() {
        window.orderOut(nil)
        viewModel.handlePanelClosed()
    }

    func setFloating(_ floating: Bool) {
        window.level = floating ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.handlePanelClosed()
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: AppViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Pick Up 阅读工作台")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Pick Up 阅读工作台"
        }

        Publishers.CombineLatest(viewModel.$phase, viewModel.speech.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, speechState in
                self?.updateStatus(phase: phase, speechState: speechState)
            }
            .store(in: &cancellables)

        viewModel.tasks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateStatus(phase: viewModel.phase, speechState: viewModel.speech.state)
                }
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        statusItem.menu = makeMenu()
        sender.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.image = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: nil)
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(menuItem("打开阅读工作台", action: #selector(openReadingWorkbench), key: "1"))
        menu.addItem(menuItem("打开任务工作台", action: #selector(openTaskWorkbench), key: "2"))
        menu.addItem(menuItem("继续与历史", action: #selector(openHistoryWorkbench), key: "3"))
        menu.addItem(menuItem("新建任务…", action: #selector(newTask), key: "n"))
        menu.addItem(menuItem("读取当前选区", action: #selector(captureSelection), key: "r", modifiers: [.command, .shift]))
        menu.addItem(menuItem("从剪贴板新建", action: #selector(captureClipboard), key: "v", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", action: #selector(openSettings), key: ","))
        let floating = menuItem("保持在前", action: #selector(toggleFloating), key: "f", modifiers: [.command, .option])
        floating.state = viewModel.keepPanelOnTop ? .on : .off
        menu.addItem(floating)
        let clear = menuItem("清除当前内容…", action: #selector(clearContent))
        clear.isEnabled = viewModel.document != nil
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Pick Up", action: #selector(quit), key: "q"))
        return menu
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private var statusTitle: String {
        if let session = viewModel.tasks.focusSession, session.state == .running {
            return "正在专注 · \(viewModel.tasks.remainingText)"
        }
        switch viewModel.speech.state {
        case .speaking: return "正在朗读"
        case .preparing: return "正在准备在线语音"
        default: return "Pick Up 已就绪"
        }
    }

    private var statusSymbol: String {
        if let session = viewModel.tasks.focusSession, session.state == .running { return "timer" }
        switch viewModel.speech.state {
        case .speaking: return "speaker.wave.2.fill"
        case .preparing: return "waveform.badge.magnifyingglass"
        default: return "text.viewfinder"
        }
    }

    @objc private func openReadingWorkbench() {
        viewModel.showReadingWorkspace()
        viewModel.onOpenPanel?()
    }
    @objc private func openTaskWorkbench() { viewModel.showTasks() }
    @objc private func openHistoryWorkbench() { viewModel.showHistory() }
    @objc private func newTask() { viewModel.showTasks(createNew: true) }
    @objc private func captureSelection() { viewModel.retryCapture() }
    @objc private func captureClipboard() { viewModel.captureClipboard() }
    @objc private func openSettings() {
        viewModel.showSettings = true
        viewModel.onOpenPanel?()
    }
    @objc private func toggleFloating() { viewModel.setKeepPanelOnTop(!viewModel.keepPanelOnTop) }
    @objc private func clearContent() {
        viewModel.requestClear()
        viewModel.onOpenPanel?()
    }
    @objc private func quit() { viewModel.quit() }

    private func updateStatus(phase: AppPhase, speechState: SpeechPlaybackState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        if let session = viewModel.tasks.focusSession, session.state == .running {
            symbol = "timer"
            description = "Pick Up 正在专注 · \(viewModel.tasks.remainingText)"
        } else if speechState == .speaking {
            symbol = "speaker.wave.2.fill"
            description = "Pick Up 正在朗读"
        } else if speechState == .preparing {
            symbol = "waveform.badge.magnifyingglass"
            description = "Pick Up 正在生成在线语音"
        } else {
            switch phase {
            case .capturing:
                symbol = "text.magnifyingglass"
                description = "Pick Up 正在捕获文字"
            case .reader:
                symbol = "text.book.closed.fill"
                description = "Pick Up 正在阅读"
            default:
                symbol = "text.viewfinder"
                description = "Pick Up 空闲"
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.toolTip = description
    }
}
