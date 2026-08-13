import SwiftUI

struct TaskWorkbenchView: View {
    @ObservedObject var viewModel: TaskWorkspaceViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTaskDescriptionFocused: Bool
    @State private var compactShowsDetail = false

    var body: some View {
        Group {
            switch viewModel.stage {
            case .list:
                taskBrowser
            case .creating:
                createTaskView
            case .clarifying:
                clarificationView
            case .editingDraft:
                draftEditor
            }
        }
        .background(PickUpBackdrop())
        .tint(PickUpTheme.indigo)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
        .pickUpAnimated(for: viewModel.stage, reduceMotion: reduceMotion)
        .onChange(of: viewModel.stage) { previous, current in
            if previous == .editingDraft, current == .list, viewModel.selectedTask != nil {
                compactShowsDetail = true
            }
        }
        .sheet(item: $viewModel.pendingAISend) { preview in
            AISendPreviewSheet(
                preview: preview,
                cancel: { viewModel.pendingAISend = nil },
                send: viewModel.confirmTaskAISend
            )
        }
        .alert("删除这个任务？", isPresented: Binding(
            get: { viewModel.taskPendingDeletion != nil },
            set: { if !$0 { viewModel.taskPendingDeletion = nil } }
        )) {
            Button("保留", role: .cancel) { viewModel.taskPendingDeletion = nil }
            Button("删除", role: .destructive) { viewModel.confirmDeleteTask() }
        } message: {
            Text("任务、步骤和专注记录将从本机删除，不会影响其他任务或阅读内容。")
        }
    }

    private var taskBrowser: some View {
        GeometryReader { geometry in
            if geometry.size.width < 700 {
                if compactShowsDetail, let task = viewModel.selectedTask {
                    VStack(spacing: 0) {
                        HStack {
                            Button("所有任务", systemImage: "chevron.left") {
                                compactShowsDetail = false
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(PickUpTheme.surface)
                        TaskDetailView(viewModel: viewModel, task: task)
                    }
                } else {
                    taskListPane
                }
            } else {
                HSplitView {
                    taskListPane
                        .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
                    taskDetailPane
                        .frame(minWidth: 380)
                }
            }
        }
        .overlay(alignment: .top) { errorBanner }
    }

    private var taskListPane: some View {
        VStack(spacing: 0) {
            HStack {
                PickUpIconBadge(symbol: "checklist", color: PickUpTheme.teal, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("我的任务")
                        .font(.headline)
                    Text("\(viewModel.activeTasks.count) 项进行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.beginCreating()
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建任务")
                .accessibilityLabel("新建任务")
            }
            .padding(14)

            List(selection: Binding(
                get: { viewModel.selectedTaskID },
                set: { id in
                    DispatchQueue.main.async {
                        if let id, let task = viewModel.tasks.first(where: { $0.id == id }) {
                            viewModel.selectTask(task)
                            compactShowsDetail = true
                        }
                    }
                }
            )) {
                if !viewModel.activeTasks.isEmpty {
                    Section("进行中") {
                        ForEach(viewModel.activeTasks) { task in
                            TaskListRow(task: task)
                                .tag(task.id)
                                .onTapGesture {
                                    viewModel.selectTask(task)
                                    compactShowsDetail = true
                                }
                        }
                    }
                }
                if !viewModel.completedTasks.isEmpty {
                    Section("已完成") {
                        ForEach(viewModel.completedTasks) { task in
                            TaskListRow(task: task)
                                .tag(task.id)
                                .onTapGesture {
                                    viewModel.selectTask(task)
                                    compactShowsDetail = true
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(PickUpTheme.surface)
            .listRowSeparator(.hidden)
            .overlay {
                if viewModel.tasks.isEmpty {
                    ContentUnavailableView(
                        "还没有任务",
                        systemImage: "checklist",
                        description: Text("写下一件想开始的事，我们一起把第一步变小。")
                    )
                }
            }
        }
        .background(PickUpTheme.surface)
    }

    @ViewBuilder
    private var taskDetailPane: some View {
        if let task = viewModel.selectedTask {
            TaskDetailView(viewModel: viewModel, task: task)
        } else {
            VStack(spacing: 16) {
                PickUpIconBadge(symbol: "figure.step.training", color: PickUpTheme.coral, size: 68)
                Text("选择一个任务，或新建任务")
                    .font(.title2.weight(.semibold))
                Button("新建任务") { viewModel.beginCreating() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var createTaskView: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { viewModel.cancelCreating() }
                Spacer()
                Text("新建任务")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 48, height: 1)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(PickUpTheme.surface)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        PickUpIconBadge(symbol: "plus.square.on.square", color: PickUpTheme.coral, size: 46)
                        Text("你想开始什么？")
                            .font(.system(.title, design: .rounded, weight: .semibold))
                        Text("一句话就够了，不需要先整理成完整计划。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.taskInput)
                            .font(.title3)
                            .focused($isTaskDescriptionFocused)
                            .frame(minHeight: 110)
                            .padding(10)
                            .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12))
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Text("\(viewModel.taskInput.count) / 2,000")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(viewModel.taskInput.count > 2_000 ? .red : .secondary)
                                    .padding(10)
                            }
                            .accessibilityLabel("任务描述")
                    }
                    .pickUpCard(tint: PickUpTheme.indigo, padding: 18)

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    localPrivacyLabel
                    Spacer()
                    breakdownButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    localPrivacyLabel
                    HStack { Spacer(); breakdownButtons }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PickUpTheme.surface)
        }
        .onAppear {
            DispatchQueue.main.async {
                isTaskDescriptionFocused = true
            }
        }
    }

    private var localPrivacyLabel: some View {
        Label("本地拆解不联网", systemImage: "lock.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var breakdownButtons: some View {
        HStack(spacing: 8) {
                Button("使用本地拆解") { viewModel.requestBreakdown(origin: .local) }
                Button("使用 AI 拆解") { viewModel.requestBreakdown(origin: .ai) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.aiSettings.isEnabled || viewModel.isGenerating)
                    .help(viewModel.aiSettings.isEnabled ? "发送前会先显示准确内容" : "请先在设置中启用 AI")
        }
    }

    private var clarificationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Button("返回") {
                viewModel.stage = .creating
                viewModel.clarificationQuestion = nil
            }
            Spacer()
            PickUpIconBadge(symbol: "questionmark.bubble.fill", color: PickUpTheme.coral, size: 64)
            Text("只确认一件事")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text(viewModel.clarificationQuestion ?? "完成后希望得到什么结果？")
                .font(.title2)
            TextField("例如：一份可以发给同事的 5 页汇报", text: $viewModel.clarificationAnswer)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .accessibilityLabel("澄清问题回答")
            HStack {
                Button("暂时跳过") { viewModel.skipClarification() }
                Spacer()
                Button("继续") { viewModel.submitClarification() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isGenerating)
            }
            Spacer()
        }
        .padding(40)
        .overlay(alignment: .top) { errorBanner }
    }

    private var draftEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回调整") { viewModel.stage = .creating }
                VStack(alignment: .leading, spacing: 2) {
                    Text("检查步骤")
                        .font(.headline)
                    Text(viewModel.draftOrigin.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加步骤") { viewModel.addDraftStep() }
                Button("保存任务") { viewModel.saveDraftTask() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(PickUpTheme.surface)
            .overlay(alignment: .bottom) {
                PickUpChromeEdge()
            }
            List {
                ForEach($viewModel.draftSteps) { $step in
                    DraftStepEditor(
                        step: $step,
                        remove: { viewModel.removeDraftStep(id: step.id) }
                    )
                }
                .onMove(perform: viewModel.moveDraftSteps)
            }
            .scrollContentBackground(.hidden)
            .background(PickUpTheme.surface)
        }
        .overlay(alignment: .top) { errorBanner }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                Spacer()
                Button("关闭") { viewModel.errorMessage = nil }
                    .buttonStyle(.plain)
            }
            .font(.callout)
            .padding(10)
            .background(PickUpTheme.coral.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PickUpTheme.coral.opacity(0.28))
            }
            .padding(10)
        }
    }
}

private struct TaskListRow: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : task.status == .paused ? "pause.circle" : "circle")
                    .foregroundStyle(task.status == .completed ? PickUpTheme.teal : task.status == .paused ? PickUpTheme.coral : PickUpTheme.indigo)
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
            Text("\(task.completedStepCount) / \(task.steps.count) 步 · \(task.status.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct DraftStepEditor: View {
    @Binding var step: TaskStepDraft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("具体动作", text: $step.action)
                    .font(.headline)
                Spacer()
                Stepper("\(step.estimatedMinutes) 分钟", value: $step.estimatedMinutes, in: 1...480, step: 5)
                    .frame(width: 150)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除步骤")
            }
            TextField("所需材料，用逗号分隔", text: Binding(
                get: { step.materials.joined(separator: "，") },
                set: { step.materials = $0.components(separatedBy: CharacterSet(charactersIn: "，,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            TextField("完成标准", text: $step.completionCriteria)
        }
        .padding(.vertical, 8)
    }
}

private struct TaskDetailView: View {
    @ObservedObject var viewModel: TaskWorkspaceViewModel
    let task: TaskItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                taskHeader
                if let current = task.currentStep {
                    CurrentStepCard(viewModel: viewModel, task: task, step: current)
                } else {
                    completedCard
                }
                FocusCard(viewModel: viewModel, task: task)
                stepList
                recentSession
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var taskHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("任务名称", text: Binding(
                    get: { task.title },
                    set: { task.title = $0 }
                ))
                .font(.largeTitle.weight(.semibold))
                .fontDesign(.rounded)
                .textFieldStyle(.plain)
                .onSubmit { viewModel.persistTaskEdits(task) }
                Label(task.planOrigin.title, systemImage: task.planOrigin == .ai ? "sparkles" : "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if task.status == .paused {
                Button("继续任务") { viewModel.resumeTask() }
            }
            Menu {
                Button("保存继续卡片…") { viewModel.requestContinuationCard() }
                Button("添加步骤") { viewModel.addStep(to: task) }
                Divider()
                Button("删除任务…", role: .destructive) { viewModel.requestDelete(task) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("任务更多操作")
        }
    }

    private var completedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(PickUpTheme.teal)
            VStack(alignment: .leading) {
                Text("这个计划已经走完")
                    .font(.headline)
                Text("你可以保留它、调整步骤，或开始另一件事。")
                    .foregroundStyle(.secondary)
            }
        }
        .pickUpCard(tint: PickUpTheme.teal, padding: 18)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部步骤")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("添加") { viewModel.addStep(to: task) }
            }
            ForEach(task.orderedSteps) { step in
                EditableTaskStepRow(
                    step: step,
                    isCurrent: task.currentStepID == step.id,
                    save: { viewModel.persistTaskEdits(task) },
                    delete: { viewModel.deleteStep(step, from: task) },
                    moveUp: { viewModel.moveStep(step, in: task, by: -1) },
                    moveDown: { viewModel.moveStep(step, in: task, by: 1) }
                )
            }
        }
    }

    @ViewBuilder
    private var recentSession: some View {
        if let session = task.sessions
            .filter({ $0.state == .ended })
            .sorted(by: { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) })
            .first {
            VStack(alignment: .leading, spacing: 6) {
                Text("最近一轮")
                    .font(.headline)
                Text(session.completionNote.isEmpty ? "这轮已经结束，可以从当前步骤继续。" : session.completionNote)
                    .foregroundStyle(.secondary)
                if let endedAt = session.endedAt {
                    Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct CurrentStepCard: View {
    @ObservedObject var viewModel: TaskWorkspaceViewModel
    let task: TaskItem
    let step: TaskStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("现在就做", systemImage: "location.fill")
                    .font(.headline)
                    .foregroundStyle(PickUpTheme.indigo)
                Spacer()
                Text("约 \(step.estimatedMinutes) 分钟")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(step.action)
                .font(.title2.weight(.semibold))
            LabeledContent("完成标准") {
                Text(step.completionCriteria)
                    .multilineTextAlignment(.trailing)
            }
            if !step.materials.isEmpty {
                LabeledContent("需要") {
                    Text(step.materials.joined(separator: "、"))
                        .multilineTextAlignment(.trailing)
                }
            }
            HStack {
                Button("稍后继续") { viewModel.pauseTask() }
                Button("跳过这步") { viewModel.skipCurrentStep() }
                    .disabled(viewModel.hasOpenFocus)
                Spacer()
                Button("标记完成") { viewModel.markCurrentStepCompleted() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.hasOpenFocus)
            }
        }
        .padding(20)
        .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PickUpTheme.indigo.opacity(0.24))
        }
        .shadow(color: .black.opacity(0.05), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
    }
}

private struct EditableTaskStepRow: View {
    let step: TaskStep
    let isCurrent: Bool
    let save: () -> Void
    let delete: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(step.status == .completed ? .green : .secondary)
                TextField("步骤动作", text: Binding(get: { step.action }, set: { step.action = $0 }))
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .onSubmit(save)
                if isCurrent {
                    Text("当前")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(PickUpTheme.indigo.opacity(0.15), in: Capsule())
                }
                Menu {
                    Button("上移", action: moveUp)
                    Button("下移", action: moveDown)
                    Divider()
                    Button("删除步骤", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
            }
            TextField("完成标准", text: Binding(get: { step.completionCriteria }, set: { step.completionCriteria = $0 }))
                .foregroundStyle(.secondary)
                .textFieldStyle(.plain)
                .onSubmit(save)
            HStack {
                TextField("所需材料，用逗号分隔", text: Binding(
                    get: { step.materials.joined(separator: "，") },
                    set: {
                        step.materials = $0.components(separatedBy: CharacterSet(charactersIn: "，,"))
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .onSubmit(save)
                Spacer()
                Stepper(
                    "\(step.estimatedMinutes) 分钟",
                    value: Binding(
                        get: { step.estimatedMinutes },
                        set: { step.estimatedMinutes = $0; save() }
                    ),
                    in: 1...480,
                    step: 5
                )
                .frame(width: 145)
            }
        }
        .padding(12)
        .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isCurrent ? PickUpTheme.indigo.opacity(0.34) : PickUpTheme.border)
        }
    }

    private var icon: String {
        switch step.status {
        case .pending: isCurrent ? "location.circle.fill" : "circle"
        case .completed: "checkmark.circle.fill"
        case .skipped: "arrow.right.circle"
        }
    }
}

private struct FocusCard: View {
    @ObservedObject var viewModel: TaskWorkspaceViewModel
    let task: TaskItem
    @State private var extendMinutes = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("专注会话")
                .font(.title3.weight(.semibold))

            if let session = viewModel.focusSession, session.taskID == task.id {
                if session.state == .awaitingReview {
                    review
                } else {
                    activeSession(session)
                }
            } else if viewModel.hasOpenFocus {
                Label("另一个任务正在专注中；暂停后可以切换。", systemImage: "timer")
                    .foregroundStyle(.secondary)
            } else if task.currentStep != nil && task.status != .completed {
                startControls
            }
        }
        .pickUpCard(tint: viewModel.focusSession?.taskID == task.id ? PickUpTheme.coral : nil, padding: 18)
    }

    private var startControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("时长", selection: $viewModel.focusMinutes) {
                Text("10 分钟").tag(10)
                Text("25 分钟").tag(25)
                Text("45 分钟").tag(45)
                Text("自定义").tag(0)
            }
            .pickerStyle(.segmented)
            if viewModel.focusMinutes == 0 {
                Stepper("\(viewModel.customFocusMinutes) 分钟", value: $viewModel.customFocusMinutes, in: 1...180)
            }
            HStack {
                Text("时间只是支持，不是评分。你随时可以暂停或调整。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("开始专注") {
                    viewModel.startFocus(minutes: viewModel.focusMinutes == 0 ? viewModel.customFocusMinutes : viewModel.focusMinutes)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func activeSession(_ session: FocusSession) -> some View {
        VStack(spacing: 12) {
            Text(viewModel.remainingText)
                .font(.system(size: 48, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(PickUpTheme.coral)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("剩余时间 \(viewModel.remainingText)")
            if viewModel.showsGentleReminder {
                Label("这一轮快到时间了，可以收尾，也可以继续。", systemImage: "bell")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if session.state == .running {
                    Button("暂停") { viewModel.pauseFocus() }
                } else {
                    Button("继续") { viewModel.resumeFocus() }
                }
                Menu("延长") {
                    Button("5 分钟") { viewModel.extendFocus(minutes: 5) }
                    Button("10 分钟") { viewModel.extendFocus(minutes: 10) }
                    Divider()
                    Stepper("\(extendMinutes) 分钟", value: $extendMinutes, in: 1...180)
                    Button("延长 \(extendMinutes) 分钟") { viewModel.extendFocus(minutes: extendMinutes) }
                }
                Button("重新开始") { viewModel.restartFocus() }
                Spacer()
                Button("提前结束") { viewModel.endFocusEarly() }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这一轮完成了什么？")
                .font(.title2.weight(.semibold))
            TextField("可选：记下一句进展", text: $viewModel.reviewNote)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("稍后继续") { viewModel.finishReview(.pauseTask) }
                Button("继续当前步骤") { viewModel.finishReview(.keepCurrent) }
                Spacer()
                Button("这一步完成了") { viewModel.finishReview(.completeStep) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct AISendPreviewSheet: View {
    let preview: AISendPreview
    let cancel: () -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                PickUpIconBadge(symbol: "sparkles", color: PickUpTheme.indigo, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("确认发送给 AI")
                        .font(.title2.weight(.semibold))
                    Text("你始终可以在联网前检查准确内容")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("用途").foregroundStyle(.secondary); Text(preview.purpose) }
                GridRow { Text("服务").foregroundStyle(.secondary); Text(preview.host) }
                GridRow { Text("模型").foregroundStyle(.secondary); Text(preview.model) }
                GridRow { Text("范围").foregroundStyle(.secondary); Text(preview.sourceDescription) }
                GridRow { Text("字符数").foregroundStyle(.secondary); Text(preview.text.count.formatted()) }
            }
            Text("将发送的准确内容")
                .font(.headline)
            ScrollView {
                Text(preview.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 160, maxHeight: 300)
            .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.10))
            }
            HStack {
                Label("只有点击发送后才会联网", systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: cancel)
                Button("发送", action: send)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 580)
        .frame(minHeight: 430)
        .background(PickUpBackdrop())
        .tint(PickUpTheme.indigo)
    }
}
