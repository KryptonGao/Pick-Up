import SwiftUI

struct StartHereView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var startHere: StartHereViewModel
    @ObservedObject private var tasks: TaskWorkspaceViewModel
    @ObservedObject private var recovery: Phase3ViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.startHere = viewModel.startHere
        self.tasks = viewModel.tasks
        self.recovery = viewModel.recovery
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 600
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                    header(compact: compact)
                    if let thread = startHere.thread {
                        if let session = focusSession, session.state != .ended {
                            focusBanner(session, compact: compact)
                        }
                        threadCard(thread, compact: compact)
                        actions(compact: compact)
                    } else {
                        emptyState
                    }
                }
                .padding(compact ? 18 : 28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PickUpBackdrop())
        .sheet(isPresented: $startHere.editingNextAction) {
            NextActionEditorSheet(startHere: startHere)
        }
        .overlay(alignment: .top) { messageBanner }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 12) {
            PickUpIconBadge(symbol: "sunrise", color: PickUpTheme.indigo, size: compact ? 34 : 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("开始这里")
                    .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                Text("回来时只面对一个现在就能做的动作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if startHere.thread != nil {
                Button("查看历史") { viewModel.showHistory() }
                    .help("进入继续与历史")
            }
        }
    }

    @ViewBuilder
    private func focusBanner(_ session: FocusSession, compact: Bool) -> some View {
        let task = tasks.tasks.first { $0.id == session.taskID }
        HStack(spacing: 14) {
            Image(systemName: session.state == .running ? "timer" : "pause.circle")
                .font(.title2)
                .foregroundStyle(PickUpTheme.coral)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.state == .running ? "正在专注" : "专注已暂停")
                    .font(.headline)
                    .foregroundStyle(PickUpTheme.coral)
                Text("\(task?.title ?? "当前任务") · \(session.state == .running ? tasks.remainingText : "随时可以继续")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.state == .running ? "回到专注" : "继续专注") {
                viewModel.beginFromStartHere()
            }
            .buttonStyle(.borderedProminent)
        }
        .pickUpCard(tint: PickUpTheme.coral, padding: compact ? 14 : 18)
        .accessibilityElement(children: .contain)
    }

    private func threadCard(_ thread: WorkThread, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                Text("我在做什么")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PickUpTheme.indigo)
                Text(thread.title)
                    .font(compact ? .title2.weight(.semibold) : .system(.title, design: .rounded, weight: .semibold))
            }

            if !completedText.isEmpty {
                FactRow(title: "已经完成", text: completedText)
            }
            if !blockerText.isEmpty {
                FactRow(title: "当前卡点", text: blockerText)
            }

            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Text("下次先做")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PickUpTheme.indigo)
                Text(thread.nextAction)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                if thread.estimatedMinutes > 0 {
                    Text("约 \(thread.estimatedMinutes) 分钟")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Label("来源：\(sourceDescription)", systemImage: "app")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("编辑下一步", systemImage: "pencil") {
                    startHere.beginEditingNextAction()
                }
            }

            if isDegraded {
                Label("原任务或阅读记录已不存在；这里的文字内容仍然保留。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(PickUpTheme.coral)
            }
        }
        .pickUpCard(tint: PickUpTheme.indigo, padding: compact ? 16 : 24)
        .accessibilityIdentifier("startHere.card")
        .accessibilityElement(children: .contain)
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.beginFromStartHere()
            } label: {
                Label("开始这一步", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .regular : .large)
            .accessibilityIdentifier("startHere.primary")
            Button("打开来源") { viewModel.openSourceFromStartHere() }
                .controlSize(compact ? .regular : .large)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            PickUpIconBadge(symbol: "sunrise", color: PickUpTheme.indigo, size: 76)
            Text("还没有正在进行的上下文接力")
                .font(.system(.title, design: .rounded, weight: .semibold))
            Text("在阅读中点击「转为任务」，或专注结束后保存继续卡片，\n这里会变成你的重进入口。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button("去阅读") { viewModel.showReader() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = startHere.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .padding(10)
                .background(PickUpTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(PickUpTheme.border))
                .padding(.top, 8)
                .onTapGesture { startHere.errorMessage = nil }
        }
    }

    private var focusSession: FocusSession? {
        tasks.focusSession
    }

    private var linkedCard: ContinuationCard? {
        guard let id = startHere.thread?.continuationCardID else { return nil }
        return recovery.cards.first { $0.id == id }
    }

    private var linkedTask: TaskItem? {
        guard let id = startHere.thread?.taskID else { return nil }
        return tasks.tasks.first { $0.id == id }
    }

    private var linkedDocument: ReadingDocument? {
        guard let id = startHere.thread?.readingDocumentID else { return nil }
        return viewModel.readingDocument(id)
    }

    private var isDegraded: Bool {
        linkedTask == nil && linkedDocument == nil && linkedCard == nil
    }

    private var completedText: String {
        if let card = linkedCard, !card.completedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return card.completedText
        }
        if let session = linkedTask?.sessions
            .filter({ $0.state == .ended && !$0.completionNote.isEmpty })
            .sorted(by: { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) })
            .first {
            return session.completionNote
        }
        return ""
    }

    private var blockerText: String {
        guard let card = linkedCard else { return "" }
        return card.blockerText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceDescription: String {
        if let card = linkedCard, !card.sourceDescription.isEmpty { return card.sourceDescription }
        if let document = linkedDocument, document.sourceAppName != "未知来源" {
            return [document.sourceAppName, document.sourceWindowTitle]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        return "本机保存的内容"
    }
}

private struct FactRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }
}

private struct NextActionEditorSheet: View {
    @ObservedObject var startHere: StartHereViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                PickUpIconBadge(symbol: "pencil.circle.fill", color: PickUpTheme.indigo, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑下一步")
                        .font(.title2.weight(.semibold))
                    Text("用“动词 + 对象”写下一个小动作。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("下次先做什么")
                    .font(.headline)
                TextField("例如：打开文档，写出 3 条结论", text: $startHere.nextActionDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.12))
                    }
                    .accessibilityIdentifier("startHere.nextAction")
            }
            HStack {
                Text("预计时间")
                    .font(.headline)
                Spacer()
                Stepper("\(startHere.estimatedMinutesDraft) 分钟", value: $startHere.estimatedMinutesDraft, in: 1...180)
                    .frame(width: 150)
            }
            if let error = startHere.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(PickUpTheme.coral)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") { startHere.cancelEditingNextAction() }
                Button("保存") { startHere.saveNextAction() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 320)
        .background(PickUpBackdrop())
        .accessibilityElement(children: .contain)
    }
}
