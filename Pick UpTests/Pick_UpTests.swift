import AppKit
import SwiftData
import Testing
@testable import Pick_Up

@Suite("中文文本分段")
struct TextSegmenterTests {
    private let segmenter = TextSegmenter()

    @Test("识别 Markdown 标题并保留 UTF-16 原文范围")
    func markdownHeadingAndRanges() {
        let text = "# 阅读标题\n\n第一句。第二句！Third sentence.\n\n结尾段落。"
        let segments = segmenter.segment(text)

        #expect(segments.first?.kind == .heading)
        #expect(segments.first?.text == "# 阅读标题")
        for segment in segments {
            let original = (text as NSString).substring(
                with: NSRange(location: segment.sourceLocation, length: segment.sourceLength)
            )
            #expect(original == segment.text)
        }
    }

    @Test("短独立行识别为标题")
    func shortStandaloneHeading() {
        let segments = segmenter.segment("项目背景\n\n这是正文，包含完整句子。")
        #expect(segments.count == 2)
        #expect(segments[0].kind == .heading)
        #expect(segments[1].kind == .paragraph)
    }

    @Test("每个阅读单元最多组合三句")
    func maximumThreeSentences() {
        let text = "第一句。第二句。第三句。第四句。"
        let segments = segmenter.segment(text)
        #expect(segments.count == 2)
        #expect(segments[0].text.contains("第三句"))
        #expect(segments[1].text.contains("第四句"))
    }

    @Test("超长单句保持完整")
    func longSentenceRemainsWhole() {
        let sentence = String(repeating: "专注", count: 200) + "。"
        let segments = segmenter.segment(sentence)
        #expect(segments.count == 1)
        #expect(segments[0].text == sentence)
        #expect(segments[0].text.count > 320)
    }

    @Test("emoji 不破坏原文映射")
    func emojiRangeMapping() {
        let text = "开始 🧠。继续工作 👩🏽‍💻！"
        let segments = segmenter.segment(text)
        for segment in segments {
            #expect(
                (text as NSString).substring(
                    with: NSRange(location: segment.sourceLocation, length: segment.sourceLength)
                ) == segment.text
            )
        }
    }
}

@Suite("剪贴板保护", .serialized)
@MainActor
struct PasteboardSnapshotTests {
    @Test("保留多个 item 和类型")
    func restoresAllItemsAndTypes() {
        let pasteboard = NSPasteboard.withUniqueName()
        let first = NSPasteboardItem()
        first.setString("原文本", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .init("space.chenkai.test-data"))
        let second = NSPasteboardItem()
        second.setString("第二项", forType: .string)
        pasteboard.writeObjects([first, second])
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("临时复制", forType: .string)
        let copiedChangeCount = pasteboard.changeCount
        #expect(snapshot.restore(to: pasteboard, ifChangeCountIs: copiedChangeCount))
        #expect(pasteboard.pasteboardItems?.count == 2)
        #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "原文本")
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .init("space.chenkai.test-data")) == Data([1, 2, 3]))
    }

    @Test("用户再次修改后不覆盖新剪贴板")
    func doesNotOverwriteNewClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("原文本", forType: .string)
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("自动复制", forType: .string)
        let copiedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("用户的新内容", forType: .string)

        #expect(!snapshot.restore(to: pasteboard, ifChangeCountIs: copiedChangeCount))
        #expect(pasteboard.string(forType: .string) == "用户的新内容")
    }
}

@Suite("自动复制生命周期", .serialized)
@MainActor
struct PasteboardCaptureServiceTests {
    @Test("复制晚到初始超时后仍会恢复原剪贴板")
    func restoresClipboardWhenCopyArrivesLate() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("原文本", forType: .string)
        let source = SourceContext(
            appName: "测试 App",
            bundleIdentifier: "space.chenkai.test",
            processIdentifier: 0,
            windowTitle: nil
        )
        let service = PasteboardCaptureService(
            pasteboard: pasteboard,
            copyTimeout: .milliseconds(20),
            lateCopyObservationWindow: .milliseconds(300),
            pollingInterval: .milliseconds(5),
            postCopyCommand: {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    pasteboard.clearContents()
                    pasteboard.setString("晚到文本", forType: .string)
                }
                return true
            }
        )

        let result = await service.captureByCopying(source: source)

        guard case .success(let payload) = result else {
            #expect(Bool(false), "晚到的复制应当被捕获")
            return
        }
        #expect(payload.text == "晚到文本")
        #expect(payload.method == .automaticClipboard)
        #expect(pasteboard.string(forType: .string) == "原文本")
    }

    @Test("取消请求时也会完成晚到复制的清理")
    func cancellationStillRestoresClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("原文本", forType: .string)
        let service = PasteboardCaptureService(
            pasteboard: pasteboard,
            copyTimeout: .milliseconds(20),
            lateCopyObservationWindow: .milliseconds(300),
            pollingInterval: .milliseconds(5),
            postCopyCommand: {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    pasteboard.clearContents()
                    pasteboard.setString("取消后晚到文本", forType: .string)
                }
                return true
            }
        )

        let captureTask = Task { @MainActor in
            await service.captureByCopying(source: .unknown)
        }
        try? await Task.sleep(for: .milliseconds(10))
        captureTask.cancel()
        let result = await captureTask.value

        guard case .success(let payload) = result else {
            #expect(Bool(false), "取消不应跳过复制生命周期的清理")
            return
        }
        #expect(payload.text == "取消后晚到文本")
        #expect(pasteboard.string(forType: .string) == "原文本")
    }
}

@Suite("本地阅读仓库", .serialized)
@MainActor
struct ReadingRepositoryTests {
    @Test("仅保留 active 文档并保存进度与重点")
    func replaceAndPersist() throws {
        let container = try makeContainer()
        let repository = ReadingRepository(container: container)
        let first = makeDocument(text: "第一份。")
        try repository.replace(with: first)
        first.currentSegmentIndex = 0
        first.segments[0].isHighlighted = true
        try repository.save()

        let loaded = try repository.loadActive()
        #expect(loaded?.originalText == "第一份。")
        #expect(loaded?.segments.first?.isHighlighted == true)

        let second = makeDocument(text: "第二份。")
        try repository.replace(with: second)
        #expect(try repository.loadActive()?.originalText == "第二份。")
    }

    @Test("清除只删除阅读内容")
    func clear() throws {
        let repository = ReadingRepository(container: try makeContainer())
        try repository.replace(with: makeDocument(text: "待清除。"))
        try repository.clear()
        #expect(try repository.loadActive() == nil)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([ReadingDocument.self, ReadingSegment.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }

    private func makeDocument(text: String) -> ReadingDocument {
        ReadingDocument(
            originalText: text,
            source: .unknown,
            captureMethod: .manualClipboard,
            wasTruncated: false,
            segments: [
                ReadingSegment(
                    order: 0,
                    kind: .paragraph,
                    text: text,
                    sourceLocation: 0,
                    sourceLength: (text as NSString).length
                )
            ]
        )
    }
}

@Suite("工作流状态")
@MainActor
struct AppViewModelTests {
    @Test("超长文本进入确认并按 Swift 字符安全截取")
    func safeLongTextTruncation() throws {
        let viewModel = try makeViewModel()
        let text = String(repeating: "🧠", count: AppViewModel.maximumCharacterCount + 1)
        viewModel.receive(.success(CapturePayload(text: text, source: .unknown, method: .manualClipboard)))

        #expect(viewModel.phase == .overLimit)
        viewModel.acceptTruncation()
        #expect(viewModel.phase == .preview)
        #expect(viewModel.draft?.text.count == AppViewModel.maximumCharacterCount)
        #expect(viewModel.draft?.text.last == "🧠")
        #expect(viewModel.draft?.wasTruncated == true)
    }

    @Test("捕获失败不会删除当前文档")
    func failedCapturePreservesDocument() async throws {
        let viewModel = try makeViewModel(selectionResult: .failure(.targetUnresponsive))
        viewModel.receive(CapturePayload(text: "已有内容。", source: .unknown, method: .manualClipboard))
        viewModel.confirmDraft()
        await viewModel.captureSelection()

        #expect(viewModel.phase == .failure(.targetUnresponsive))
        #expect(viewModel.document?.originalText == "已有内容。")
    }

    @Test("朗读速度限制为 0.5 到 2 倍")
    func speechRateBounds() throws {
        let viewModel = try makeViewModel()
        viewModel.speech.setRate(9)
        #expect(viewModel.speech.rate == 2.0)
        viewModel.speech.setRate(0.1)
        #expect(viewModel.speech.rate == 0.5)
    }

    private func makeViewModel(
        selectionResult: CaptureResult = .failure(.permissionRequired)
    ) throws -> AppViewModel {
        let schema = Schema([ReadingDocument.self, ReadingSegment.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let suiteName = "PickUpTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "hasCompletedOnboarding")
        return AppViewModel(
            repository: ReadingRepository(container: container),
            selectionCapturer: SelectionCaptureStub(result: selectionResult),
            clipboardCapturer: ClipboardCaptureStub(),
            segmenter: TextSegmenter(),
            speech: SpeechController(),
            defaults: defaults
        )
    }
}

@Suite("Edge 在线语音")
@MainActor
struct EdgeTTSTests {
    @Test("速度倍率转换为 Edge 百分比")
    func edgeRateConversion() {
        #expect(EdgeTTSClient.edgeRate(for: 0.5) == "-50%")
        #expect(EdgeTTSClient.edgeRate(for: 1.0) == "+0%")
        #expect(EdgeTTSClient.edgeRate(for: 1.5) == "+50%")
        #expect(EdgeTTSClient.edgeRate(for: 3.0) == "+100%")
    }

    @Test("SSML 转义特殊字符并展开音色名称")
    func ssmlEscaping() {
        let value = EdgeTTSClient.ssml(
            text: "中文 & <标签> '引号'",
            voice: "zh-CN-YunyangNeural",
            rate: 1.0
        )
        #expect(value.contains("&amp;"))
        #expect(value.contains("&lt;标签&gt;"))
        #expect(value.contains("&apos;引号&apos;"))
        #expect(value.contains("(zh-CN, YunyangNeural)"))
    }

    @Test("长文本按转义后的 UTF-8 长度安全分块")
    func safeChunking() {
        let text = String(repeating: "🧠&中文", count: 100)
        let chunks = EdgeTTSClient.textChunks(text, maximumEscapedByteCount: 60)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { EdgeTTSClient.ssml(text: $0, voice: EdgeVoice.defaultVoiceID, rate: 1).utf8.count > 0 })
    }

    @Test("在线朗读需确认且偏好被保存")
    func consentAndPreferences() {
        let suiteName = "PickUpSpeechTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let speech = SpeechController(defaults: defaults, edgeClient: EdgeTTSStub())

        #expect(speech.engine == .edge)
        speech.speak(text: "需要确认。", segmentID: nil)
        #expect(speech.requiresOnlineConsent)
        speech.declineOnlineUse()
        #expect(speech.state == .idle)

        speech.setEdgeVoice("zh-CN-XiaoxiaoNeural")
        speech.setRate(1.4)
        speech.confirmOnlineUse()
        #expect(defaults.bool(forKey: "edgeTTSOnlineConsent"))
        #expect(defaults.string(forKey: "edgeVoiceID") == "zh-CN-XiaoxiaoNeural")
        #expect(defaults.double(forKey: "speechRate") == 1.4)
    }

    @Test("播放当前句时并行预取下一句")
    func prefetchesNextSentenceDuringPlayback() async {
        let suiteName = "PickUpPrefetchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "edgeTTSOnlineConsent")
        let stub = PrefetchEdgeTTSStub()
        let speech = SpeechController(defaults: defaults, edgeClient: stub)

        speech.speak(text: "第一句。第二句。", segmentID: nil)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var observedConcurrentPrefetch = false
        while clock.now < deadline {
            if await stub.requestCount >= 2, speech.state == .speaking {
                observedConcurrentPrefetch = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(observedConcurrentPrefetch)
        speech.stop()
    }

    @Test("停止朗读会取消尚未完成的预取")
    func stopCancelsPrefetch() async {
        let suiteName = "PickUpPrefetchCancelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "edgeTTSOnlineConsent")
        let stub = PrefetchEdgeTTSStub(nextRequestDelay: .seconds(5))
        let speech = SpeechController(defaults: defaults, edgeClient: stub)

        speech.speak(text: "第一句。第二句。", segmentID: nil)
        for _ in 0..<100 {
            if await stub.requestCount >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await stub.requestCount == 2)

        speech.stop()
        for _ in 0..<100 {
            if await stub.wasCancelled { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await stub.wasCancelled)
        #expect(speech.state == .idle)
    }
}

private struct EdgeTTSStub: EdgeTTSSynthesizing {
    func synthesize(text: String, voice: String, rate: Double) async throws -> Data {
        Data()
    }
}

private actor PrefetchEdgeTTSStub: EdgeTTSSynthesizing {
    private(set) var requestCount = 0
    private(set) var wasCancelled = false
    private let nextRequestDelay: Duration

    init(nextRequestDelay: Duration = .milliseconds(80)) {
        self.nextRequestDelay = nextRequestDelay
    }

    func synthesize(text: String, voice: String, rate: Double) async throws -> Data {
        requestCount += 1
        if requestCount > 1 {
            do {
                try await Task.sleep(for: nextRequestDelay)
            } catch is CancellationError {
                wasCancelled = true
                throw CancellationError()
            }
        }
        return makeSilentWAV(duration: 0.5)
    }
}

private nonisolated func makeSilentWAV(duration: Double) -> Data {
    let sampleRate: UInt32 = 8_000
    let channelCount: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let sampleCount = Int(Double(sampleRate) * duration)
    let audioByteCount = UInt32(sampleCount * Int(bitsPerSample / 8))
    let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
    let blockAlignment = channelCount * (bitsPerSample / 8)
    var data = Data()

    func append(_ string: String) {
        data.append(contentsOf: string.utf8)
    }
    func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    append("RIFF")
    appendUInt32(36 + audioByteCount)
    append("WAVE")
    append("fmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(channelCount)
    appendUInt32(sampleRate)
    appendUInt32(byteRate)
    appendUInt16(blockAlignment)
    appendUInt16(bitsPerSample)
    append("data")
    appendUInt32(audioByteCount)
    data.append(Data(repeating: 0, count: Int(audioByteCount)))
    return data
}

private struct SelectionCaptureStub: SelectionCapturing {
    let result: CaptureResult
    func capture(from source: SourceContext) async -> CaptureResult { result }
}

@MainActor
private final class ClipboardCaptureStub: ClipboardCapturing {
    func captureCurrent(source: SourceContext) -> CaptureResult { .failure(.clipboardEmpty) }
    func captureByCopying(source: SourceContext) async -> CaptureResult { .failure(.clipboardUnchanged) }
}
