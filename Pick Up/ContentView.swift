import AppKit
import KeyboardShortcuts
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PickUpBackdrop()
            if viewModel.phase == .onboarding {
                OnboardingView(viewModel: viewModel)
                    .id("onboarding")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
                    .pickUpAnimated(for: viewModel.phase == .onboarding, reduceMotion: reduceMotion)
            } else {
                AdaptiveWorkbench(viewModel: viewModel)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .tint(PickUpTheme.indigo)
        .preferredColorScheme(.light)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(item: Binding(
            get: { viewModel.recovery.pendingDraft },
            set: { viewModel.recovery.pendingDraft = $0 }
        )) { draft in
            ContinueCardEditorSheet(
                draft: draft,
                cancel: { viewModel.recovery.pendingDraft = nil },
                save: viewModel.recovery.saveDraft
            )
        }
        .alert("替换当前阅读内容？", isPresented: $viewModel.showReplaceConfirmation) {
            Button("保留当前内容", role: .cancel) {}
            Button("替换") { viewModel.confirmReplacement() }
        } message: {
            Text("当前阅读视图会切换到新内容；旧内容仍可在“继续与历史”中查看或删除。")
        }
        .alert("清除当前内容？", isPresented: $viewModel.showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { viewModel.confirmClear() }
        } message: {
            Text("只删除当前阅读内容；其他本地历史和阅读偏好不会改变。")
        }
    }
}

private struct AdaptiveWorkbench: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                DesktopWorkbench(viewModel: viewModel)
            } else {
                CompactWorkbench(viewModel: viewModel)
            }
        }
    }
}

private struct CompactWorkbench: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceModeBar(viewModel: viewModel)
            WorkspaceDetail(viewModel: viewModel)
        }
    }
}

private struct DesktopWorkbench: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkbenchSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 270)
        } detail: {
            VStack(spacing: 0) {
                DesktopWorkspaceHeader(viewModel: viewModel)
                WorkspaceDetail(viewModel: viewModel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(PickUpTheme.surface)
    }
}

private struct WorkbenchSidebar: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var tasks: TaskWorkspaceViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.tasks = viewModel.tasks
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PickUpIconBadge(symbol: "text.viewfinder", size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pick Up")
                        .font(.headline)
                    Text("阅读与行动工作台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityIdentifier("workbench.sidebar.header")

            List(selection: workspaceSelection) {
                Section("工作台") {
                    SidebarDestinationRow(
                        title: "阅读",
                        subtitle: readingSubtitle,
                        symbol: "text.book.closed",
                        shortcut: "⌘1"
                    )
                    .tag(WorkspaceMode.reading)

                    SidebarDestinationRow(
                        title: "任务",
                        subtitle: tasks.tasks.isEmpty ? "拆解并推进下一步" : "\(tasks.activeTasks.count) 项进行中",
                        symbol: "checklist",
                        shortcut: "⌘2"
                    )
                    .tag(WorkspaceMode.tasks)

                    SidebarDestinationRow(
                        title: "继续",
                        subtitle: viewModel.recovery.latestOpenCard?.nextAction ?? "恢复上下文与本地历史",
                        symbol: "clock.arrow.circlepath",
                        shortcut: "⌘3"
                    )
                    .tag(WorkspaceMode.history)
                }

                if let session = tasks.focusSession,
                   let task = tasks.tasks.first(where: { $0.id == session.taskID }),
                   session.state != .ended {
                    Section("当前专注") {
                        Button {
                            viewModel.showTasks()
                            tasks.selectedTaskID = task.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(task.title, systemImage: session.state == .running ? "timer" : "pause.circle")
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(session.state == .running ? tasks.remainingText : "已暂停")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("快速操作") {
                    Button {
                        viewModel.retryCapture()
                    } label: {
                        SidebarActionRow(title: "读取当前选区", symbol: "text.viewfinder", shortcut: "⇧⌘R")
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.captureClipboard()
                    } label: {
                        SidebarActionRow(title: "从剪贴板新建", symbol: "doc.on.clipboard", shortcut: "⇧⌘V")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(PickUpTheme.surface)
            .listRowSeparator(.hidden)

            VStack(spacing: 4) {
                Button {
                    viewModel.setKeepPanelOnTop(!viewModel.keepPanelOnTop)
                } label: {
                    SidebarActionRow(
                        title: "保持在前",
                        symbol: viewModel.keepPanelOnTop ? "pin.fill" : "pin",
                        shortcut: "⌥⌘F"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.showSettings = true
                } label: {
                    SidebarActionRow(title: "设置", symbol: "gearshape", shortcut: "⌘,")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开设置")
            }
            .padding(10)
            .background(PickUpTheme.surface)
            .overlay(alignment: .top) { PickUpChromeEdge() }
        }
        .background(PickUpTheme.surface)
    }

    private var workspaceSelection: Binding<WorkspaceMode?> {
        Binding(
            get: { viewModel.workspaceMode },
            set: { mode in
                guard let mode else { return }
                viewModel.workspaceMode = mode
            }
        )
    }

    private var readingSubtitle: String {
        guard let document = viewModel.document else { return "捕获并专注阅读" }
        return "\(document.orderedSegments.count) 个段落"
    }
}

private struct SidebarDestinationRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(PickUpTheme.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(shortcut)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarActionRow: View {
    let title: String
    let symbol: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 17)
            Text(title)
            Spacer(minLength: 6)
            Text(shortcut)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

private struct DesktopWorkspaceHeader: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var tasks: TaskWorkspaceViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.tasks = viewModel.tasks
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            focusStatus
            if viewModel.workspaceMode == .tasks {
                Button {
                    viewModel.showTasks(createNew: true)
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            } else if viewModel.workspaceMode == .reading {
                Button {
                    viewModel.captureClipboard()
                } label: {
                    Label("从剪贴板新建", systemImage: "doc.on.clipboard")
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(PickUpTheme.surface)
        .overlay(alignment: .bottom) { PickUpChromeEdge() }
    }

    private var headerTitle: String {
        switch viewModel.workspaceMode {
        case .reading: "阅读工作台"
        case .tasks: "任务工作台"
        case .history: "继续与历史"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.workspaceMode {
        case .reading: "一次专注一段重要内容"
        case .tasks: "把想法变成可以立刻开始的下一步"
        case .history: "快速找回上下文，所有记录默认只在本机"
        }
    }

    @ViewBuilder
    private var focusStatus: some View {
        if let session = tasks.focusSession,
           let task = tasks.tasks.first(where: { $0.id == session.taskID }),
           session.state != .ended {
            Button {
                viewModel.showTasks()
                tasks.selectedTaskID = task.id
            } label: {
                PickUpStatusPill(
                    title: session.state == .running ? "\(task.title) · \(tasks.remainingText)" : "\(task.title) · 已暂停",
                    symbol: session.state == .running ? "timer" : "pause.circle",
                    color: session.state == .running ? PickUpTheme.coral : PickUpTheme.indigo
                )
            }
            .buttonStyle(.plain)
            .lineLimit(1)
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if viewModel.workspaceMode == .tasks {
                TaskWorkbenchView(viewModel: viewModel.tasks)
            } else if viewModel.workspaceMode == .history {
                Phase3View(viewModel: viewModel.recovery)
            } else {
                readingContent
            }
        }
        .id(phaseIdentifier)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
        .pickUpAnimated(for: phaseIdentifier, reduceMotion: reduceMotion)
    }

    private var phaseIdentifier: String {
        if viewModel.workspaceMode == .tasks {
            return "tasks-\(viewModel.tasks.stage)"
        }
        if viewModel.workspaceMode == .history {
            return "history"
        }
        return switch viewModel.phase {
        case .onboarding: "onboarding"
        case .idle: "idle"
        case .capturing: "capturing"
        case .preview: "preview"
        case .overLimit: "overLimit"
        case .reader: "reader"
        case .failure(let issue): "failure-\(issue.title)"
        }
    }

    @ViewBuilder
    private var readingContent: some View {
        switch viewModel.phase {
        case .onboarding:
            EmptyView()
        case .idle:
            EmptyWorkbenchView(viewModel: viewModel)
        case .capturing:
            CaptureProgressView()
        case .preview:
            CapturePreviewView(viewModel: viewModel)
        case .overLimit:
            LongTextView(viewModel: viewModel)
        case .reader:
            ReaderView(viewModel: viewModel)
        case .failure(let issue):
            CaptureFailureView(viewModel: viewModel, issue: issue)
        }
    }
}

private struct WorkspaceModeBar: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var tasks: TaskWorkspaceViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.tasks = viewModel.tasks
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                workspacePicker
                focusStatus
                Spacer(minLength: 8)
                windowControls
            }

            HStack(spacing: 10) {
                workspacePicker
                Spacer(minLength: 4)
                windowControls
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(PickUpTheme.surface)
        .overlay(alignment: .bottom) {
            PickUpChromeEdge()
        }
    }

    private var workspacePicker: some View {
        Picker("工作台模式", selection: $viewModel.workspaceMode) {
            ForEach(WorkspaceMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 220)
        .accessibilityLabel("工作台模式")
    }

    @ViewBuilder
    private var focusStatus: some View {
        if let session = tasks.focusSession,
           let task = tasks.tasks.first(where: { $0.id == session.taskID }),
           session.state != .ended {
            Button {
                viewModel.workspaceMode = .tasks
                tasks.selectedTaskID = task.id
            } label: {
                PickUpStatusPill(
                    title: session.state == .running ? "\(task.title) · \(tasks.remainingText)" : "\(task.title) · 已暂停",
                    symbol: session.state == .running ? "timer" : "pause.circle",
                    color: session.state == .running ? PickUpTheme.coral : PickUpTheme.indigo
                )
            }
            .buttonStyle(.plain)
            .lineLimit(1)
            .accessibilityLabel("打开当前专注任务")
        }
    }

    private var windowControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { viewModel.keepPanelOnTop },
                set: viewModel.setKeepPanelOnTop
            )) {
                Image(systemName: viewModel.keepPanelOnTop ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help("保持工作台在其他窗口上方")
            .accessibilityLabel("保持在前")
            Button {
                viewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
            .accessibilityLabel("打开设置")
        }
        .fixedSize()
    }
}

private struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var step = 0
    @State private var recordedShortcut = KeyboardShortcuts.getShortcut(for: .captureSelection)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            PickUpIconBadge(symbol: stepSymbol, color: stepColor, size: 72)
                .padding(.bottom, 22)

            VStack(spacing: 10) {
                Text(stepTitle)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text(stepMessage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 520)
                    .accessibilityIdentifier("onboarding.step.description")
            }

            Group {
                if step == 0 {
                    Label("只有你主动触发时，Pick Up 才会读取文字", systemImage: "lock.shield.fill")
                        .foregroundStyle(PickUpTheme.teal)
                } else if step == 1 {
                    KeyboardShortcuts.Recorder(
                        "读取当前选区",
                        name: .captureSelection
                    ) { shortcut in
                        recordedShortcut = shortcut
                    }
                    .frame(maxWidth: 360)
                    .accessibilityLabel("录制读取当前选区的全局快捷键")
                } else {
                    Label(
                        viewModel.isAccessibilityTrusted ? "已授权辅助功能访问" : "尚未授权；仍可使用剪贴板",
                        systemImage: viewModel.isAccessibilityTrusted ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(viewModel.isAccessibilityTrusted ? PickUpTheme.teal : .secondary)
                }
            }
            .frame(maxWidth: 440)
            .pickUpCard(tint: stepColor, padding: 16)
            .padding(.top, 24)
            .id(step)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            .pickUpAnimated(for: step, reduceMotion: reduceMotion)

            Spacer()

            HStack {
                if step > 0 {
                    Button("返回") { step -= 1 }
                }
                Spacer()
                if step == 2 {
                    Button("暂时跳过") { viewModel.completeOnboarding() }
                    Button("请求权限") { viewModel.requestAccessibilityPermission() }
                    Button("开始使用") { viewModel.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("继续") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .disabled(step == 1 && recordedShortcut == nil)
                }
            }
            .padding(18)
            .background(PickUpTheme.surface)
        }
        .padding(.top, 34)
    }

    private var stepSymbol: String {
        ["hand.raised.fill", "command", "figure.wave"][step]
    }

    private var stepColor: Color {
        [PickUpTheme.indigo, PickUpTheme.coral, PickUpTheme.teal][step]
    }

    private var stepTitle: String {
        ["文字由你决定何时读取", "录制一个顺手的快捷键", "允许跨 App 读取选区"][step]
    }

    private var stepMessage: String {
        [
            "Pick Up 只在你主动按下快捷键时读取当前选中的文字。它不会持续录屏或记录键盘输入；只有你确认使用在线朗读时，待朗读文字才会发送给 Microsoft。",
            "我们不会预占你的系统快捷键。录制时会自动提示与系统或 App 菜单的冲突。",
            "辅助功能权限用于读取你主动选择的文字。你可以暂时跳过，先复制文字，再从菜单栏使用剪贴板入口。"
        ][step]
    }
}

private struct EmptyWorkbenchView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            PickUpIconBadge(symbol: "text.viewfinder", size: 76)
            Text("从当前文字开始")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text("在任意 App 中选择文字后按下全局快捷键，\n或先复制文字，再从剪贴板新建。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
            HStack(spacing: 12) {
                Button("读取当前选区") { viewModel.retryCapture() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                Button("从剪贴板新建") { viewModel.captureClipboard() }
            }
            .controlSize(.large)
            Label("文字默认只保存在这台 Mac", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Spacer()
        }
        .padding(32)
    }
}

private struct CaptureProgressView: View {
    var body: some View {
        VStack(spacing: 18) {
            PickUpIconBadge(symbol: "text.magnifyingglass", color: PickUpTheme.teal, size: 68)
            ProgressView()
                .controlSize(.large)
            Text("正在读取你主动选择的文字…")
                .font(.title3.weight(.medium))
            Text("内容准备好后会先让你确认")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在捕获文字")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkbenchHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            PickUpStatusPill(title: "确认后才会保存在本机", symbol: "lock.fill", color: PickUpTheme.teal)
        }
    }
}

private struct CapturePreviewView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeader(title: "确认文字")
            if let draft = viewModel.draft {
                SourceSummary(draft: draft)
                    .pickUpCard(padding: 14)
                Text("确认后才会保存到本机并进行分段。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(draft.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.10))
                }
                HStack {
                    Button("返回原 App") { viewModel.hideWorkbench() }
                    Button("取消") { viewModel.cancelDraft() }
                    Spacer()
                    Button("分段阅读") { viewModel.confirmDraft() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}

private struct SourceSummary: View {
    let draft: CaptureDraft

    var body: some View {
        HStack(spacing: 16) {
            Label(draft.source.appName, systemImage: "app")
            if let title = draft.source.windowTitle {
                Label(title, systemImage: "macwindow")
                    .lineLimit(1)
            }
            Spacer()
            Text(draft.method.title)
            Text("\(draft.characterCount.formatted()) 字符")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct LongTextView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            PickUpIconBadge(symbol: "doc.badge.ellipsis", color: PickUpTheme.coral, size: 72)
            Text("这段文字很长")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text("为了保持分段和朗读稳定，Phase 1 一次最多处理 100,000 个字符。你可以处理开头部分，或返回重新选择。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            if let count = viewModel.draft?.characterCount {
                Text("当前共 \(count.formatted()) 个字符")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(PickUpTheme.coral.opacity(0.12), in: Capsule())
            }
            HStack {
                Button("返回重选") { viewModel.cancelDraft() }
                Button("处理前 100,000 字符") { viewModel.acceptTruncation() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(40)
    }
}

private struct CaptureFailureView: View {
    @ObservedObject var viewModel: AppViewModel
    let issue: CaptureIssue

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            PickUpIconBadge(
                symbol: issue == .permissionRequired ? "hand.raised.slash" : "exclamationmark.bubble",
                color: PickUpTheme.coral,
                size: 72
            )
            Text(issue.title)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text(issue.message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 520)
            HStack {
                Button("返回原 App") { viewModel.hideWorkbench() }
                Button("从剪贴板读取") { viewModel.captureClipboard() }
                if issue == .permissionRequired {
                    Button("打开系统设置") { viewModel.openAccessibilitySettings() }
                }
                Button("重试") { viewModel.retryCapture() }
                    .buttonStyle(.borderedProminent)
            }
            if viewModel.document != nil {
                Button("回到当前阅读") { viewModel.showReader() }
            }
            Spacer()
        }
        .padding(40)
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var speech: SpeechController
    @ObservedObject private var ai: AISettingsStore
    @Environment(\.dismiss) private var dismiss

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.speech = viewModel.speech
        self.ai = viewModel.aiSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PickUpIconBadge(symbol: "gearshape.fill", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("设置")
                        .font(.title2.weight(.semibold))
                    Text("让 Pick Up 适合你的工作方式")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Form {
                Section("快捷键与权限") {
                    KeyboardShortcuts.Recorder("读取当前选区", name: .captureSelection)
                    LabeledContent("辅助功能") {
                        HStack {
                            Text(viewModel.isAccessibilityTrusted ? "已授权" : "未授权")
                            Button("请求权限") { viewModel.requestAccessibilityPermission() }
                            Button("打开系统设置") { viewModel.openAccessibilitySettings() }
                        }
                    }
                    Toggle("保持工作台在前", isOn: Binding(
                        get: { viewModel.keepPanelOnTop },
                        set: viewModel.setKeepPanelOnTop
                    ))
                }

                Section("文字朗读") {
                    Picker("朗读引擎", selection: Binding(
                        get: { speech.engine },
                        set: speech.setEngine
                    )) {
                        ForEach(SpeechEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }

                    if speech.engine == .edge {
                        Picker("在线音色", selection: Binding(
                            get: { speech.selectedEdgeVoiceID },
                            set: speech.setEdgeVoice
                        )) {
                            ForEach(EdgeVoice.catalog) { voice in
                                VStack(alignment: .leading) {
                                    Text(voice.name)
                                    Text(voice.detail)
                                }
                                .tag(voice.id)
                            }
                        }

                        LabeledContent("当前音色") {
                            Text("\(speech.selectedEdgeVoice.name) · \(speech.selectedEdgeVoice.detail)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            if speech.hasOnlineConsent {
                                Label("已允许发送待朗读文字", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                Button("撤回允许") { speech.resetOnlineConsent() }
                            } else {
                                Label("朗读前需要确认联网", systemImage: "network")
                                    .foregroundStyle(.secondary)
                                Button("同意使用在线朗读") { speech.confirmOnlineUse() }
                            }
                            Spacer()
                            Button("试听音色") { speech.previewSelectedVoice() }
                        }
                    } else {
                        Text("本地语音不上传文字，具体音色由 macOS 已安装的系统声音决定。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("BYOK AI（可选）") {
                    Toggle("启用 AI 辅助", isOn: $ai.isEnabled)
                    TextField("API Base URL", text: $ai.baseURL)
                        .textContentType(.URL)
                    TextField("模型名称", text: $ai.model)
                    HStack {
                        SecureField(ai.hasStoredKey ? "已保存；输入新 Key 可替换" : "API Key", text: $ai.apiKeyDraft)
                            .accessibilityIdentifier("ai.apiKey")
                        Button("粘贴") { pasteAPIKey() }
                            .accessibilityHint("从剪贴板读取 API Key，但不会立即保存或发送")
                    }
                    HStack {
                        Button(ai.hasStoredKey ? "替换 Key" : "保存 Key") { ai.saveAPIKey() }
                            .disabled(ai.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if ai.hasStoredKey {
                            Button("移除 Key", role: .destructive) { ai.clearAPIKey() }
                        }
                        Spacer()
                        Button(ai.isTesting ? "正在测试…" : "测试连接") {
                            viewModel.tasks.testAIConnection()
                        }
                        .disabled(ai.isTesting)
                    }
                    if let message = ai.statusMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("远程地址必须使用 HTTPS；HTTP 仅允许 localhost、127.0.0.1 或 ::1。本机服务可以不填写 Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text("Pick Up 不会持续读取屏幕或键盘。AI 默认关闭，每次发送前都会展示服务、模型和准确文本；API Key 只保存在 macOS 钥匙串。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(PickUpTheme.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(28)
        .frame(width: 620)
        .frame(minHeight: 620)
        .background(PickUpBackdrop())
        .tint(PickUpTheme.indigo)
        .alert(
            "使用 Microsoft Edge 在线语音？",
            isPresented: Binding(
                get: { speech.requiresOnlineConsent },
                set: { if !$0, speech.requiresOnlineConsent { speech.declineOnlineUse() } }
            )
        ) {
            Button("取消", role: .cancel) { speech.declineOnlineUse() }
            Button("同意并朗读") { speech.confirmOnlineUse() }
        } message: {
            Text(onlineSpeechConsentMessage)
        }
    }

    private var onlineSpeechConsentMessage: String {
        "待朗读的文字会通过网络发送到 Microsoft Edge 在线语音服务并转换为音频。Pick Up 不会上传其他阅读内容；该服务是非官方开放接口，可能随时发生变化。"
    }

    private func pasteAPIKey() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            ai.statusMessage = "剪贴板里没有可粘贴的文字。"
            return
        }
        ai.apiKeyDraft = value
        ai.statusMessage = "已粘贴，点击保存后才会写入钥匙串。"
    }
}
