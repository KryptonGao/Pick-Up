import SwiftUI

struct Phase3View: View {
    @ObservedObject var viewModel: Phase3ViewModel
    @State private var showExport = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 700 {
                compactLayout
            } else {
                HSplitView {
                    historyList.frame(minWidth: 240, idealWidth: 290, maxWidth: 350)
                    detail.frame(minWidth: 380)
                }
            }
        }
        .background(PickUpBackdrop())
        .overlay(alignment: .top) { messageBanner }
        .sheet(isPresented: $showExport) {
            ExportPreviewSheet(viewModel: viewModel, isPresented: $showExport)
        }
        .alert("删除这条记录？", isPresented: Binding(
            get: { viewModel.recordPendingDeletion != nil },
            set: { if !$0 { viewModel.recordPendingDeletion = nil } }
        )) {
            Button("保留", role: .cancel) { viewModel.recordPendingDeletion = nil }
            Button("删除", role: .destructive) { viewModel.confirmDelete() }
        } message: {
            Text("只删除选中的记录，不会影响其他本地历史。")
        }
        .alert("删除全部本地历史？", isPresented: $viewModel.showDeleteAllConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) { viewModel.confirmDeleteAll() }
        } message: {
            Text("任务、专注记录、继续卡片和保存的文本都会从本机删除。此操作无法撤销。")
        }
        .onAppear { viewModel.reload() }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            if let card = viewModel.selectedCard {
                HStack {
                    Button("返回历史", systemImage: "chevron.left") { viewModel.selectedRecordID = nil }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(PickUpTheme.surface)
                ContinueCardDetail(viewModel: viewModel, card: card)
            } else {
                historyList
            }
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PickUpIconBadge(symbol: "clock.arrow.circlepath", color: PickUpTheme.teal, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("继续与历史").font(.headline)
                        Text("全部保存在这台 Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                TextField("搜索任务、来源或内容", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索本地历史")
            }
            .padding(14)

            if let latest = viewModel.latestOpenCard {
                Button { select(latest) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("上次做到这里", systemImage: "arrow.uturn.forward.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PickUpTheme.indigo)
                        Text(latest.taskTitle).font(.headline).lineLimit(1)
                        Text(latest.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pickUpCard(tint: PickUpTheme.indigo, padding: 12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .accessibilityLabel("上次做到这里，\(latest.taskTitle)，下一步，\(latest.nextAction)")
            }

            List(selection: $viewModel.selectedRecordID) {
                ForEach(viewModel.filteredRecords) { record in
                    HistoryRow(record: record)
                        .tag(record.id)
                        .contextMenu {
                            Button("删除…", role: .destructive) { viewModel.requestDelete(record) }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(PickUpTheme.surface)
            .listRowSeparator(.hidden)
            .overlay {
                if viewModel.filteredRecords.isEmpty {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "还没有本地历史" : "没有匹配的记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(viewModel.searchText.isEmpty ? "完成一轮专注或保存阅读内容后，会在这里出现。" : "换一个关键词试试。")
                    )
                }
            }

            HStack {
                Button("导出", systemImage: "square.and.arrow.up") { showExport = true }
                    .disabled(viewModel.records.isEmpty)
                Spacer()
                Button("删除全部…", role: .destructive) { viewModel.showDeleteAllConfirmation = true }
                    .disabled(viewModel.records.isEmpty)
            }
            .padding(10)
            .background(PickUpTheme.surface)
        }
        .background(PickUpTheme.surface)
    }

    @ViewBuilder
    private var detail: some View {
        if let card = viewModel.selectedCard {
            ContinueCardDetail(viewModel: viewModel, card: card)
        } else if let id = viewModel.selectedRecordID,
                  let record = viewModel.records.first(where: { $0.id == id }) {
            HistoryRecordDetail(viewModel: viewModel, record: record)
        } else if let latest = viewModel.latestOpenCard {
            ContinueCardDetail(viewModel: viewModel, card: latest)
        } else {
            ContentUnavailableView(
                "选择一条历史",
                systemImage: "clock.arrow.circlepath",
                description: Text("查看来源、时间和保存的上下文。")
            )
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = viewModel.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .padding(10)
                .background(PickUpTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(PickUpTheme.border))
                .padding(.top, 8)
                .onTapGesture { viewModel.errorMessage = nil }
        } else if let message = viewModel.statusMessage {
            Label(message, systemImage: "checkmark.circle")
                .padding(10)
                .background(PickUpTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(PickUpTheme.border))
                .padding(.top, 8)
                .onTapGesture { viewModel.statusMessage = nil }
        }
    }

    private func select(_ card: ContinuationCard) {
        viewModel.selectedRecordID = "\(HistoryRecordKind.continuation.rawValue)-\(card.id.uuidString)"
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.kind.symbol)
                .foregroundStyle(record.kind == .continuation ? PickUpTheme.indigo : PickUpTheme.teal)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(record.createdAt, format: .dateTime.month().day())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(record.kind.title).font(.caption2).foregroundStyle(.secondary)
                Text(record.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.kind.title)，\(record.title)，\(record.detail)")
    }
}

private struct ContinueCardDetail: View {
    @ObservedObject var viewModel: Phase3ViewModel
    let card: ContinuationCard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PickUpIconBadge(symbol: "arrow.uturn.forward.circle.fill", color: PickUpTheme.indigo, size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("继续工作卡片").font(.caption.weight(.semibold)).foregroundStyle(PickUpTheme.indigo)
                        TextField("我正在做什么", text: binding(\.taskTitle))
                            .font(.largeTitle.weight(.semibold)).textFieldStyle(.plain)
                            .accessibilityLabel("我正在做什么")
                    }
                    Spacer()
                    Button("继续工作", systemImage: "play.fill") { viewModel.resume(card) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Menu {
                        Button("关闭卡片") { viewModel.close(card) }
                        Divider()
                        Button("删除…", role: .destructive) {
                            if let record = viewModel.records.first(where: { $0.modelID == card.id && $0.kind == .continuation }) {
                                viewModel.requestDelete(record)
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("继续卡片更多操作")
                }

                CardField(title: "已经完成", placeholder: "记下一句可见进展", text: binding(\.completedText), axis: .vertical)
                CardField(title: "当前卡在哪里", placeholder: "例如：还缺一个数据来源", text: binding(\.blockerText), axis: .vertical)
                CardField(title: "下次回来先做什么", placeholder: "用具体动词写下一个小动作", text: binding(\.nextAction), axis: .vertical, emphasized: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("相关位置").font(.headline)
                    HStack {
                        TextField("来源 App", text: binding(\.sourceAppName))
                        TextField("窗口标题", text: binding(\.sourceWindowTitle))
                    }
                    TextField("文件或项目线索", text: binding(\.fileHint))
                    TextField("相关文本（只保存你主动填写的内容）", text: binding(\.relatedText), axis: .vertical)
                        .lineLimit(2...5)
                    Label("Pick Up 不会在后台读取窗口或文件内容", systemImage: "hand.raised.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .pickUpCard(padding: 16)

                HStack {
                    Text("更新于 \(card.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存修改") { viewModel.saveEdits(to: card) }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<ContinuationCard, String>) -> Binding<String> {
        Binding(get: { card[keyPath: keyPath] }, set: { card[keyPath: keyPath] = $0 })
    }
}

private struct CardField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(emphasized ? PickUpTheme.indigo : .primary)
            TextField(placeholder, text: $text, axis: axis)
                .textFieldStyle(.plain)
                .lineLimit(axis == .vertical ? 2...5 : 1...1)
                .font(emphasized ? .title3.weight(.semibold) : .body)
        }
        .pickUpCard(tint: emphasized ? PickUpTheme.indigo : nil, padding: 16)
        .accessibilityElement(children: .contain)
    }
}

private struct HistoryRecordDetail: View {
    @ObservedObject var viewModel: Phase3ViewModel
    let record: HistoryRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PickUpIconBadge(symbol: record.kind.symbol, color: PickUpTheme.teal, size: 54)
                Text(record.kind.title).font(.caption.weight(.semibold)).foregroundStyle(PickUpTheme.teal)
                Text(record.title).font(.largeTitle.weight(.semibold))
                Text(record.detail).font(.title3).textSelection(.enabled)
                LabeledContent("时间", value: record.createdAt.formatted(date: .complete, time: .shortened))
                LabeledContent("来源", value: record.source)
                HStack {
                    Spacer()
                    Button("删除这条记录…", role: .destructive) { viewModel.requestDelete(record) }
                }
            }
            .pickUpCard(padding: 22)
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ContinueCardEditorSheet: View {
    @State private var draft: ContinuationCardDraft
    let cancel: () -> Void
    let save: (ContinuationCardDraft) -> Void

    init(draft: ContinuationCardDraft, cancel: @escaping () -> Void, save: @escaping (ContinuationCardDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.cancel = cancel
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PickUpIconBadge(symbol: "arrow.uturn.forward.circle.fill", color: PickUpTheme.indigo, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("保存继续工作卡片").font(.title2.weight(.semibold))
                    Text("只保存你在这里确认的内容，稍后都可以修改。").foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("我正在做什么", text: $draft.taskTitle)
                TextField("已经完成了什么", text: $draft.completedText, axis: .vertical).lineLimit(2...4)
                TextField("当前卡在哪里", text: $draft.blockerText, axis: .vertical).lineLimit(2...4)
                TextField("下次回来先做什么", text: $draft.nextAction, axis: .vertical).lineLimit(2...4)
                Section("相关位置（可选）") {
                    TextField("来源 App", text: $draft.sourceAppName)
                    TextField("窗口标题", text: $draft.sourceWindowTitle)
                    TextField("文件或项目线索", text: $draft.fileHint)
                    TextField("相关文本", text: $draft.relatedText, axis: .vertical).lineLimit(2...5)
                }
            }
            HStack {
                Label("不会自动读取后台窗口", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("暂不保存", action: cancel)
                Button("保存在本机") { save(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: 610)
        .background(PickUpBackdrop())
        .accessibilityElement(children: .contain)
    }
}

private struct ExportPreviewSheet: View {
    @ObservedObject var viewModel: Phase3ViewModel
    @Binding var isPresented: Bool
    @State private var format: HistoryExportFormat = .markdown
    @State private var filteredOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出本地历史").font(.title2.weight(.semibold))
            Text("导出前确认内容范围和文件格式。本地记录只有在你选择位置后才会写入文件。")
                .foregroundStyle(.secondary)
            Picker("格式", selection: $format) {
                ForEach(HistoryExportFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("只导出当前搜索结果", isOn: $filteredOnly)
                .disabled(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let count = filteredOnly ? viewModel.filteredRecords.count : viewModel.records.count
            GroupBox("将要导出的范围") {
                HStack {
                    Label("\(count) 条记录", systemImage: "doc.on.doc")
                    Spacer()
                    Text(format.title).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("选择保存位置") {
                    isPresented = false
                    viewModel.export(format: format, filteredOnly: filteredOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
            }
        }
        .padding(24)
        .frame(width: 520, height: 330)
        .background(PickUpBackdrop())
    }
}
