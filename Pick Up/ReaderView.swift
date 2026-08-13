import AppKit
import SwiftUI

struct ReaderView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var speech: SpeechController
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 8.0
    @AppStorage("readerColumnWidth") private var columnWidth = 680.0
    @AppStorage("readerBackground") private var backgroundRawValue = ReadingBackground.system.rawValue
    @AppStorage("readerHighContrast") private var highContrast = false
    @State private var selectedText = ""
    @State private var aiScope: ReadingAIScope = .currentSegment
    @State private var aiPreview: AISendPreview?
    @State private var pendingAIAction: ReadingAIAction?
    @State private var pendingAIText = ""
    @State private var pendingAIScopeTitle = ""
    @State private var presentedAIResult: PresentedReadingAIResult?
    @State private var isAIProcessing = false
    @State private var aiError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.speech = viewModel.speech
    }

    var body: some View {
        GeometryReader { geometry in
            let compactHeight = geometry.size.height < 560

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, compactHeight ? 8 : 12)
                    .background(PickUpTheme.surface)
                    .overlay(alignment: .bottom) {
                        PickUpChromeEdge()
                    }
                if let document = viewModel.document {
                    if document.wasTruncated {
                        Label("当前内容已截取为前 100,000 个字符", systemImage: "scissors")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, compactHeight ? 5 : 8)
                            .background(Color.orange.opacity(0.15))
                            .accessibilityElement(children: .combine)
                    }
                    content(document, compactHeight: compactHeight)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                }
                controls
                    .padding(.horizontal, 16)
                    .padding(.vertical, compactHeight ? 8 : 10)
                    .background(PickUpTheme.surface)
                    .overlay(alignment: .top) {
                        PickUpChromeEdge()
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(readingBackground)
        .foregroundStyle(readingForeground)
        .tint(PickUpTheme.indigo)
        .onChange(of: viewModel.document?.currentSegmentIndex) { _, _ in
            DispatchQueue.main.async {
                selectedText = ""
                aiScope = .currentSegment
            }
        }
        .onChange(of: selectedText) { _, value in
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async { aiScope = .selection }
            }
        }
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
            Text("待朗读的文字会通过网络发送到 Microsoft Edge 在线语音服务并转换为音频。Pick Up 不会上传其他阅读内容；该服务是非官方开放接口，可能随时发生变化。")
        }
        .sheet(item: $aiPreview) { preview in
            AISendPreviewSheet(
                preview: preview,
                cancel: {
                    aiPreview = nil
                    pendingAIAction = nil
                    pendingAIText = ""
                },
                send: runReadingAI
            )
        }
        .sheet(item: $presentedAIResult) { presentation in
            ReadingAIResultView(presentation: presentation)
        }
        .alert("AI 暂时不可用", isPresented: Binding(
            get: { aiError != nil },
            set: { if !$0 { aiError = nil } }
        )) {
            Button("好") { aiError = nil }
        } message: {
            Text(aiError ?? "请稍后重试。")
        }
        .overlay {
            if isAIProcessing {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("AI 正在处理你确认发送的内容…")
                        .padding(22)
                        .background(PickUpTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                newCaptureButton
                readingModePicker
                Spacer(minLength: 12)
                sourceSummary
                appearanceMenu
                aiMenu
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    newCaptureButton
                    readingModePicker
                    Spacer(minLength: 4)
                    appearanceMenu
                }
                HStack(spacing: 10) {
                    compactSourceSummary
                    Spacer(minLength: 8)
                    aiMenu
                }
            }
        }
    }

    private var newCaptureButton: some View {
        Button {
            viewModel.newCapture()
        } label: {
            Label("新建", systemImage: "plus")
        }
    }

    private var readingModePicker: some View {
        Picker("阅读模式", selection: $viewModel.readingMode) {
            ForEach(ReadingMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
        .accessibilityLabel("阅读模式")
    }

    @ViewBuilder
    private var sourceSummary: some View {
        if let document = viewModel.document {
            VStack(alignment: .trailing, spacing: 2) {
                Text(document.sourceAppName)
                    .font(.callout.weight(.medium))
                if let title = document.sourceWindowTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 150, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("来源：\(document.sourceAppName)，\(document.sourceWindowTitle ?? "窗口标题不可用")")
        }
    }

    @ViewBuilder
    private var compactSourceSummary: some View {
        if let document = viewModel.document {
            Label(document.sourceAppName, systemImage: "doc.text")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("来源：\(document.sourceAppName)，\(document.sourceWindowTitle ?? "窗口标题不可用")")
        }
    }

    private var appearanceMenu: some View {
        Menu {
            ReaderPreferencesView(
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                columnWidth: $columnWidth,
                backgroundRawValue: $backgroundRawValue,
                highContrast: $highContrast
            )
        } label: {
            Image(systemName: "textformat.size")
        }
        .help("阅读外观")
        .accessibilityLabel("调整阅读外观")
    }

    private var aiMenu: some View {
        Menu {
            Picker("发送范围", selection: $aiScope) {
                Text("选中文字").tag(ReadingAIScope.selection)
                    .disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("当前段落").tag(ReadingAIScope.currentSegment)
                Text("全文").tag(ReadingAIScope.fullDocument)
            }
            Divider()
            ForEach(ReadingAIAction.allCases) { action in
                Button(action.title) { prepareReadingAI(action) }
            }
        } label: {
            Label("AI 辅助", systemImage: "sparkles")
        }
        .help("发送前会先展示准确文本")
        .accessibilityLabel("AI 阅读辅助")
    }

    @ViewBuilder
    private func content(_ document: ReadingDocument, compactHeight: Bool) -> some View {
        switch viewModel.readingMode {
        case .focused:
            focusedReading(document, compactHeight: compactHeight)
        case .continuous:
            continuousReading(document, highlightsOnly: false)
        case .highlights:
            continuousReading(document, highlightsOnly: true)
        }
    }

    private func focusedReading(_ document: ReadingDocument, compactHeight: Bool) -> some View {
        let segments = document.orderedSegments
        let index = min(max(document.currentSegmentIndex, 0), max(segments.count - 1, 0))
        let segment = segments.indices.contains(index) ? segments[index] : nil

        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text(segments.isEmpty ? "没有可显示的段落" : "第 \(index + 1) / \(segments.count) 段")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let segment {
                        Button {
                            viewModel.toggleHighlight(segment)
                        } label: {
                            Label(segment.isHighlighted ? "已标记重点" : "标记重点", systemImage: segment.isHighlighted ? "bookmark.fill" : "bookmark")
                        }
                        .foregroundStyle(segment.isHighlighted ? PickUpTheme.coral : .secondary)
                        .accessibilityHint("切换当前段落的重点标记")
                    }
                }
                ProgressView(value: segments.isEmpty ? 0 : Double(index + 1), total: Double(max(segments.count, 1)))
                    .tint(PickUpTheme.teal)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, compactHeight ? 8 : 12)

            Spacer(minLength: compactHeight ? 4 : 12)
            if let segment {
                VStack(spacing: 16) {
                    if segment.kind == .heading {
                        Text("标题")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    SelectableReaderText(
                        text: segment.text,
                        selectedText: $selectedText,
                        highlightedRange: speech.highlight?.segmentID == segment.id ? speech.highlight?.range : nil,
                        fontSize: segment.kind == .heading ? fontSize + 6 : fontSize,
                        lineSpacing: lineSpacing,
                        foregroundColor: nsForegroundColor,
                        backgroundColor: nsBackgroundColor,
                        alignment: segment.kind == .heading ? .center : .natural
                    )
                    .frame(
                        maxWidth: columnWidth,
                        minHeight: compactHeight ? 56 : 120,
                        maxHeight: compactHeight ? 108 : 360
                    )
                    .accessibilityLabel(segment.kind == .heading ? "标题" : "第 \(index + 1) 段")
                }
                .padding(compactHeight ? 12 : 24)
                .background(
                    Color(nsColor: nsBackgroundColor).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(highContrast ? 0.35 : 0.10), lineWidth: highContrast ? 2 : 1)
                }
                .shadow(color: .black.opacity(highContrast ? 0 : 0.08), radius: 18, y: 8)
                .padding(.horizontal, compactHeight ? 16 : 28)
                .id(segment.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                .pickUpAnimated(for: segment.id, reduceMotion: reduceMotion)
            }
            Spacer(minLength: compactHeight ? 4 : 12)

            HStack(spacing: 16) {
                Button {
                    viewModel.moveCurrentSegment(by: -1)
                } label: {
                    Label("上一段", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(index == 0)

                Button {
                    viewModel.moveCurrentSegment(by: 1)
                } label: {
                    Label("下一段", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(index >= segments.count - 1)
            }
            .controlSize(compactHeight ? .regular : .large)
            .padding(.bottom, compactHeight ? 8 : 20)
        }
    }

    private func continuousReading(_ document: ReadingDocument, highlightsOnly: Bool) -> some View {
        let allSegments = document.orderedSegments
        let segments = highlightsOnly ? allSegments.filter(\.isHighlighted) : allSegments

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if segments.isEmpty {
                        ContentUnavailableView(
                            "还没有重点",
                            systemImage: "bookmark",
                            description: Text("在逐段或连续阅读中标记希望稍后回看的内容。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    }
                    ForEach(segments) { segment in
                        SegmentCard(
                            segment: segment,
                            isSpeaking: speech.highlight?.segmentID == segment.id,
                            fontSize: segment.kind == .heading ? fontSize + 5 : fontSize,
                            lineSpacing: lineSpacing,
                            highContrast: highContrast,
                            toggleHighlight: { viewModel.toggleHighlight(segment) },
                            speak: { speech.speak(text: segment.text, segmentID: segment.id) }
                        )
                        .id(segment.id)
                        .onTapGesture {
                            if let index = allSegments.firstIndex(where: { $0.id == segment.id }) {
                                viewModel.selectSegment(index: index)
                            }
                        }
                    }
                }
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            .onChange(of: speech.highlight) { _, highlight in
                if let id = highlight?.segmentID {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.16) : PickUpTheme.quickSpring) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let issue) = speech.state {
                HStack(spacing: 8) {
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if issue == .onlineSpeechUnavailable {
                        Button("改用本地语音") { speech.retryWithSystemVoice() }
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    playbackButtons
                    Spacer(minLength: 8)
                    speechOptions
                    taskButton
                    continuationButton
                    clearButton
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        playbackButtons
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        speechOptions
                        Spacer(minLength: 4)
                        taskButton
                        continuationButton
                        clearButton
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackButtons: some View {
        switch speech.state {
        case .preparing:
            Button {} label: { Label("正在生成", systemImage: "waveform") }
                .disabled(true)
        case .speaking:
            Button { speech.pause() } label: { Label("暂停", systemImage: "pause.fill") }
                .buttonStyle(.borderedProminent)
        case .paused:
            Button { speech.resume() } label: { Label("继续", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        default:
            Button { speakCurrent() } label: { Label("朗读当前段", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
        }
        Button("朗读选中", systemImage: "selection.pin.in.out") {
            speech.speak(text: selectedText, segmentID: viewModel.currentSegment?.id)
        }
        .disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("朗读全文", systemImage: "speaker.wave.2") { speakAll() }
            .disabled(viewModel.document?.segments.isEmpty != false)
        if speech.state == .preparing || speech.state == .speaking || speech.state == .paused {
            Button("停止", systemImage: "stop.fill") { speech.stop() }
        }
    }

    private var speechOptions: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("朗读引擎", selection: Binding(
                    get: { speech.engine },
                    set: speech.setEngine
                )) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                if speech.engine == .edge {
                    Divider()
                    ForEach(EdgeVoice.catalog) { voice in
                        Button {
                            speech.setEdgeVoice(voice.id)
                        } label: {
                            if voice.id == speech.selectedEdgeVoiceID {
                                Label("\(voice.name) · \(voice.detail)", systemImage: "checkmark")
                            } else {
                                Text("\(voice.name) · \(voice.detail)")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    speech.engine == .edge ? speech.selectedEdgeVoice.name : "本地",
                    systemImage: speech.engine == .edge ? "network" : "desktopcomputer"
                )
            }
            .help(speech.engine.title)
            Text("\(speech.rate, specifier: "%.1f")×")
                .font(.caption.monospacedDigit())
            Slider(
                value: Binding(get: { speech.rate }, set: speech.setRate),
                in: 0.5...2.0,
                step: 0.1
            )
            .frame(minWidth: 80, idealWidth: 110, maxWidth: 140)
            .accessibilityLabel("朗读速度")
            .accessibilityValue("\(speech.rate, specifier: "%.1f") 倍")
        }
    }

    private var clearButton: some View {
        Button("清除", systemImage: "trash", role: .destructive) { viewModel.requestClear() }
    }

    private var continuationButton: some View {
        Button("保存继续卡片", systemImage: "arrow.uturn.forward.circle") {
            viewModel.saveReadingContinuationCard()
        }
        .help("保存当前阅读位置和下一步")
    }

    private var taskButton: some View {
        Button("转为任务", systemImage: "square.and.pencil") {
            viewModel.prepareTaskFromReading(selected: selectedText)
        }
        .help("把当前段落或选中文字变成可开始的任务")
    }

    private func speakCurrent() {
        guard let segment = viewModel.currentSegment else { return }
        speech.speak(text: segment.text, segmentID: segment.id)
    }

    private func speakAll() {
        let items = viewModel.document?.orderedSegments.map { (id: $0.id, text: $0.text) } ?? []
        speech.speak(segments: items)
    }

    private func prepareReadingAI(_ action: ReadingAIAction) {
        do {
            let configuration = try viewModel.aiSettings.configuration()
            let source = try readingAISource()
            guard source.text.count <= 20_000 else {
                throw AIServiceError.inputTooLong(limit: 20_000)
            }
            pendingAIAction = action
            pendingAIText = source.text
            pendingAIScopeTitle = source.scopeTitle
            aiPreview = AISendPreview(
                purpose: action.title,
                text: source.text,
                sourceDescription: source.scopeTitle,
                host: configuration.displayHost,
                model: configuration.model
            )
        } catch {
            aiError = readableAIError(error)
        }
    }

    private func runReadingAI() {
        guard let action = pendingAIAction, !pendingAIText.isEmpty else { return }
        do {
            let configuration = try viewModel.aiSettings.configuration()
            let text = pendingAIText
            let scopeTitle = pendingAIScopeTitle
            aiPreview = nil
            isAIProcessing = true
            Task {
                do {
                    let result = try await AIWorkflows.assistReading(
                        action: action,
                        text: text,
                        client: viewModel.aiClient,
                        configuration: configuration
                    )
                    presentedAIResult = PresentedReadingAIResult(
                        result: result,
                        action: action,
                        model: configuration.model,
                        scopeTitle: scopeTitle,
                        sourceText: text
                    )
                } catch {
                    aiError = readableAIError(error)
                }
                isAIProcessing = false
                pendingAIAction = nil
                pendingAIText = ""
            }
        } catch {
            aiPreview = nil
            aiError = readableAIError(error)
        }
    }

    private func readingAISource() throws -> (text: String, scopeTitle: String) {
        switch aiScope {
        case .selection:
            let clean = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return (clean, "你在当前段落中选中的文字") }
            aiScope = .currentSegment
            fallthrough
        case .currentSegment:
            guard let text = viewModel.currentSegment?.text, !text.isEmpty else {
                throw AIServiceError.invalidResponse
            }
            return (text, "当前段落")
        case .fullDocument:
            guard let text = viewModel.document?.originalText, !text.isEmpty else {
                throw AIServiceError.invalidResponse
            }
            return (text, "当前阅读全文")
        }
    }

    private func readableAIError(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "AI 请求没有完成，原文保持不变。"
    }

    private var chosenBackground: ReadingBackground {
        ReadingBackground(rawValue: backgroundRawValue) ?? .system
    }

    private var readingBackground: Color { Color(nsColor: nsBackgroundColor) }
    private var readingForeground: Color { Color(nsColor: nsForegroundColor) }

    private var nsBackgroundColor: NSColor {
        if highContrast { return chosenBackground == .dark ? .black : .white }
        switch chosenBackground {
        case .system: return .white
        case .warm: return NSColor(red: 0.98, green: 0.95, blue: 0.86, alpha: 1)
        case .softGray: return NSColor(red: 0.92, green: 0.93, blue: 0.94, alpha: 1)
        case .dark: return NSColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
        }
    }

    private var nsForegroundColor: NSColor {
        chosenBackground == .dark ? .white : .black
    }
}

private struct PresentedReadingAIResult: Identifiable {
    let id = UUID()
    let result: ReadingAIResult
    let action: ReadingAIAction
    let model: String
    let scopeTitle: String
    let sourceText: String
}

private struct ReadingAIResultView: View {
    let presentation: PresentedReadingAIResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("AI 生成 · \(presentation.action.title)", systemImage: "sparkles")
                        .font(.title2.weight(.semibold))
                    Text("\(presentation.model) · \(presentation.scopeTitle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("原文没有被修改。每项结果都保留模型给出的原文依据。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(presentation.result.items) { item in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(item.heading)
                                .font(.headline)
                            Text(item.output)
                                .textSelection(.enabled)
                            Divider()
                            if presentation.sourceText.contains(item.sourceQuote) {
                                Label("原文依据", systemImage: "text.quote")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.sourceQuote)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else {
                                Label("AI 未定位到原文，请自行核对", systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .pickUpCard(padding: 16)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 600)
    }
}

private struct SegmentCard: View {
    let segment: ReadingSegment
    let isSpeaking: Bool
    let fontSize: Double
    let lineSpacing: Double
    let highContrast: Bool
    let toggleHighlight: () -> Void
    let speak: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(segment.text)
                .font(segment.kind == .heading ? .system(size: fontSize, weight: .semibold) : .system(size: fontSize))
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: segment.kind == .heading ? .center : .leading)
            HStack {
                Button(action: toggleHighlight) {
                    Label(segment.isHighlighted ? "已标记" : "标记重点", systemImage: segment.isHighlighted ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.plain)
                Button(action: speak) { Label("朗读", systemImage: "speaker.wave.2") }
                    .buttonStyle(.plain)
            }
            .font(.callout)
        }
        .padding(20)
        .background(
            isSpeaking ? PickUpTheme.indigo.opacity(highContrast ? 0.25 : 0.14) : PickUpTheme.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            if isSpeaking || highContrast {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSpeaking ? PickUpTheme.indigo : Color.primary, lineWidth: highContrast ? 2 : 1)
            }
        }
        .shadow(color: .black.opacity(highContrast ? 0 : 0.05), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}

private struct ReaderPreferencesView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var columnWidth: Double
    @Binding var backgroundRawValue: String
    @Binding var highContrast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("字号 \(Int(fontSize))")
            Slider(value: $fontSize, in: 16...36, step: 1)
            Text("行距 \(Int(lineSpacing))")
            Slider(value: $lineSpacing, in: 4...20, step: 1)
            Picker("列宽", selection: $columnWidth) {
                Text("窄").tag(560.0)
                Text("舒适").tag(680.0)
                Text("宽").tag(800.0)
            }
            Picker("背景", selection: $backgroundRawValue) {
                ForEach(ReadingBackground.allCases) { background in
                    Text(background.title).tag(background.rawValue)
                }
            }
            Toggle("高对比度", isOn: $highContrast)
        }
        .padding(10)
        .frame(width: 280)
    }
}

private struct SelectableReaderText: NSViewRepresentable {
    let text: String
    @Binding var selectedText: String
    let highlightedRange: NSRange?
    let fontSize: Double
    let lineSpacing: Double
    let foregroundColor: NSColor
    let backgroundColor: NSColor
    let alignment: NSTextAlignment

    func makeCoordinator() -> Coordinator { Coordinator(selectedText: $selectedText) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: alignment == .center ? .semibold : .regular),
            .foregroundColor: foregroundColor,
            .backgroundColor: backgroundColor,
            .paragraphStyle: paragraph
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        if let range = highlightedRange,
           range.location >= 0,
           NSMaxRange(range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.28), range: range)
        }
        let textChanged = textView.attributedString().string != text
        if textChanged || highlightedRange != context.coordinator.lastHighlight {
            context.coordinator.isUpdatingProgrammatically = true
            defer { context.coordinator.isUpdatingProgrammatically = false }
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributed)
            if !textChanged, NSMaxRange(selectedRange) <= attributed.length {
                textView.setSelectedRange(selectedRange)
            } else if textChanged {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            context.coordinator.lastHighlight = highlightedRange
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var selectedText: String
        var lastHighlight: NSRange?
        var isUpdatingProgrammatically = false

        init(selectedText: Binding<String>) {
            _selectedText = selectedText
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingProgrammatically else { return }
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let value = if range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length {
                (textView.string as NSString).substring(with: range)
            } else {
                ""
            }
            DispatchQueue.main.async { [weak self] in self?.selectedText = value }
        }
    }
}
