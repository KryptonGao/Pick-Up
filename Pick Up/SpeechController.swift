import AVFoundation
import Combine
import Foundation
import NaturalLanguage

enum SpeechPlaybackState: Equatable {
    case idle
    case preparing
    case speaking
    case paused
    case failed(CaptureIssue)
}

struct SpeechHighlight: Equatable {
    let segmentID: UUID?
    let range: NSRange
}

@MainActor
protocol SpeechControlling: AnyObject {
    var state: SpeechPlaybackState { get }
    var highlight: SpeechHighlight? { get }
    func speak(text: String, segmentID: UUID?)
    func pause()
    func resume()
    func stop()
    func setRate(_ rate: Double)
}

@MainActor
final class SpeechController: NSObject, ObservableObject, SpeechControlling {
    @Published private(set) var state: SpeechPlaybackState = .idle
    @Published private(set) var highlight: SpeechHighlight?
    @Published private(set) var rate: Double
    @Published private(set) var engine: SpeechEngine
    @Published private(set) var selectedEdgeVoiceID: String
    @Published private(set) var requiresOnlineConsent = false

    var selectedEdgeVoice: EdgeVoice { EdgeVoice.voice(for: selectedEdgeVoiceID) }
    var hasOnlineConsent: Bool { defaults.bool(forKey: Self.onlineConsentKey) }

    private struct QueueItem {
        let text: String
        let segmentID: UUID?
        let range: NSRange
    }

    private struct UtteranceContext {
        let segmentID: UUID?
        let baseLocation: Int
        let generation: UInt
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let tokenizer = NLTokenizer(unit: .sentence)
    private let edgeClient: any EdgeTTSSynthesizing
    private let defaults: UserDefaults
    private var contextByUtterance: [ObjectIdentifier: UtteranceContext] = [:]
    private var edgeTask: Task<Void, Never>?
    private var edgePrefetchTask: Task<Data, Error>?
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Bool, Never>?
    private var pendingOnlineItems: [QueueItem]?
    private var lastRequestedItems: [QueueItem] = []
    private var playbackGeneration: UInt = 0
    private var pauseRequested = false

    private static let engineKey = "speechEngine"
    private static let voiceKey = "edgeVoiceID"
    private static let rateKey = "speechRate"
    private static let onlineConsentKey = "edgeTTSOnlineConsent"

    init(
        defaults: UserDefaults = .standard,
        edgeClient: (any EdgeTTSSynthesizing)? = nil
    ) {
        self.defaults = defaults
        self.edgeClient = edgeClient ?? EdgeTTSClient()
        let savedRate = defaults.double(forKey: Self.rateKey)
        self.rate = savedRate == 0 ? 1.0 : min(max(savedRate, 0.5), 2.0)
        self.engine = SpeechEngine(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .edge
        let savedVoiceID = defaults.string(forKey: Self.voiceKey) ?? EdgeVoice.defaultVoiceID
        self.selectedEdgeVoiceID = EdgeVoice.catalog.contains(where: { $0.id == savedVoiceID })
            ? savedVoiceID
            : EdgeVoice.defaultVoiceID
        super.init()
        synthesizer.delegate = self
    }

    func speak(text: String, segmentID: UUID?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(.speechUnavailable)
            return
        }
        begin(items: queueItems(text: text, segmentID: segmentID))
    }

    func speak(segments: [(id: UUID, text: String)]) {
        let items = segments.flatMap { queueItems(text: $0.text, segmentID: $0.id) }
        guard !items.isEmpty else {
            state = .failed(.speechUnavailable)
            return
        }
        begin(items: items)
    }

    func previewSelectedVoice() {
        speak(text: "你好，这是 \(selectedEdgeVoice.name) 的朗读效果。", segmentID: nil)
    }

    func setEngine(_ engine: SpeechEngine) {
        guard self.engine != engine else { return }
        stop()
        self.engine = engine
        defaults.set(engine.rawValue, forKey: Self.engineKey)
    }

    func setEdgeVoice(_ voiceID: String) {
        guard EdgeVoice.catalog.contains(where: { $0.id == voiceID }) else { return }
        if selectedEdgeVoiceID != voiceID { stop() }
        selectedEdgeVoiceID = voiceID
        defaults.set(voiceID, forKey: Self.voiceKey)
    }

    func confirmOnlineUse() {
        defaults.set(true, forKey: Self.onlineConsentKey)
        requiresOnlineConsent = false
        guard let items = pendingOnlineItems else { return }
        pendingOnlineItems = nil
        begin(items: items)
    }

    func declineOnlineUse() {
        pendingOnlineItems = nil
        requiresOnlineConsent = false
        state = .idle
    }

    func resetOnlineConsent() {
        stop()
        defaults.set(false, forKey: Self.onlineConsentKey)
    }

    func retryWithSystemVoice() {
        guard !lastRequestedItems.isEmpty else { return }
        let items = lastRequestedItems
        setEngine(.system)
        begin(items: items)
    }

    func pause() {
        switch engine {
        case .system:
            guard synthesizer.isSpeaking else { return }
            if synthesizer.pauseSpeaking(at: .word) { state = .paused }
        case .edge:
            guard state == .preparing || state == .speaking else { return }
            pauseRequested = true
            audioPlayer?.pause()
            state = .paused
        }
    }

    func resume() {
        switch engine {
        case .system:
            guard synthesizer.isPaused else { return }
            if synthesizer.continueSpeaking() { state = .speaking }
        case .edge:
            guard state == .paused else { return }
            pauseRequested = false
            if let audioPlayer {
                if audioPlayer.play() { state = .speaking }
            } else {
                state = .preparing
            }
        }
    }

    func stop() {
        playbackGeneration &+= 1
        edgeTask?.cancel()
        edgeTask = nil
        edgePrefetchTask?.cancel()
        edgePrefetchTask = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        finishAudioPlayback(success: false)
        contextByUtterance.removeAll()
        pendingOnlineItems = nil
        requiresOnlineConsent = false
        pauseRequested = false
        highlight = nil
        state = .idle
    }

    func setRate(_ rate: Double) {
        self.rate = min(max(rate, 0.5), 2.0)
        defaults.set(self.rate, forKey: Self.rateKey)
    }

    private func begin(items: [QueueItem]) {
        stop()
        guard !items.isEmpty else {
            state = .failed(.speechUnavailable)
            return
        }
        lastRequestedItems = items

        switch engine {
        case .system:
            startSystemSpeech(items)
        case .edge:
            guard hasOnlineConsent else {
                pendingOnlineItems = items
                requiresOnlineConsent = true
                return
            }
            startEdgeSpeech(items)
        }
    }

    private func startSystemSpeech(_ items: [QueueItem]) {
        let generation = playbackGeneration
        for item in items {
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.voice = preferredLocalVoice(for: item.text)
            utterance.rate = Float(
                AVSpeechUtteranceDefaultSpeechRate * Float(rate)
            ).clamped(to: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
            contextByUtterance[ObjectIdentifier(utterance)] = UtteranceContext(
                segmentID: item.segmentID,
                baseLocation: item.range.location,
                generation: generation
            )
            synthesizer.speak(utterance)
        }
        state = .speaking
    }

    private func startEdgeSpeech(_ items: [QueueItem]) {
        let generation = playbackGeneration
        let voice = selectedEdgeVoiceID
        let requestRate = rate
        state = .preparing
        edgeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let firstItem = items.first else { return }
                var currentAudio = try await edgeClient.synthesize(
                    text: firstItem.text,
                    voice: voice,
                    rate: requestRate
                )

                for index in items.indices {
                    try Task.checkCancellation()
                    guard generation == playbackGeneration else { return }
                    let item = items[index]

                    // Keep only one request ahead. While the current sentence is
                    // playing, the next sentence is generated in parallel.
                    if items.indices.contains(index + 1) {
                        let nextItem = items[index + 1]
                        edgePrefetchTask = Task { [edgeClient] in
                            try await edgeClient.synthesize(
                                text: nextItem.text,
                                voice: voice,
                                rate: requestRate
                            )
                        }
                    } else {
                        edgePrefetchTask = nil
                    }

                    let player = try AVAudioPlayer(data: currentAudio)
                    player.delegate = self
                    player.prepareToPlay()
                    audioPlayer = player
                    highlight = SpeechHighlight(segmentID: item.segmentID, range: item.range)
                    let completed = await waitForPlayback(player)
                    guard generation == playbackGeneration else {
                        edgePrefetchTask?.cancel()
                        edgePrefetchTask = nil
                        return
                    }
                    guard completed else {
                        edgePrefetchTask?.cancel()
                        edgePrefetchTask = nil
                        throw EdgeTTSError.unexpectedResponse
                    }
                    audioPlayer = nil

                    if let prefetchTask = edgePrefetchTask {
                        if !pauseRequested { state = .preparing }
                        currentAudio = try await prefetchTask.value
                        edgePrefetchTask = nil
                    }
                }
                guard generation == playbackGeneration else { return }
                edgeTask = nil
                edgePrefetchTask = nil
                highlight = nil
                state = .idle
            } catch is CancellationError {
                edgePrefetchTask?.cancel()
                edgePrefetchTask = nil
                // stop() already reset the published state.
            } catch {
                edgePrefetchTask?.cancel()
                edgePrefetchTask = nil
                guard generation == playbackGeneration else { return }
                edgeTask = nil
                audioPlayer = nil
                highlight = nil
                state = .failed(.onlineSpeechUnavailable)
            }
        }
    }

    private func waitForPlayback(_ player: AVAudioPlayer) async -> Bool {
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            if pauseRequested {
                state = .paused
            } else if player.play() {
                state = .speaking
            } else {
                finishAudioPlayback(success: false)
            }
        }
    }

    private func finishAudioPlayback(success: Bool) {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume(returning: success)
    }

    private func queueItems(text: String, segmentID: UUID?) -> [QueueItem] {
        sentenceRanges(in: text).map { range in
            QueueItem(
                text: (text as NSString).substring(with: range),
                segmentID: segmentID,
                range: range
            )
        }
    }

    private func sentenceRanges(in text: String) -> [NSRange] {
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        let sentences = ranges.map { NSRange($0, in: text) }.filter { $0.length > 0 }
        return sentences.isEmpty ? [NSRange(location: 0, length: (text as NSString).length)] : sentences
    }

    private func preferredLocalVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let language = recognizer.dominantLanguage
        let identifier = language == .english ? "en-US" : "zh-CN"
        return AVSpeechSynthesisVoice(language: identifier)
            ?? AVSpeechSynthesisVoice(language: "zh-Hans")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  let context = contextByUtterance[utteranceID],
                  context.generation == playbackGeneration else { return }
            highlight = SpeechHighlight(
                segmentID: context.segmentID,
                range: NSRange(
                    location: context.baseLocation + characterRange.location,
                    length: characterRange.length
                )
            )
            state = .speaking
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didPause utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.state = .paused }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didContinue utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.state = .speaking }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        let isStillSpeaking = synthesizer.isSpeaking
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = contextByUtterance.removeValue(forKey: utteranceID)
            guard context?.generation == playbackGeneration else { return }
            if !isStillSpeaking {
                highlight = nil
                state = .idle
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = contextByUtterance.removeValue(forKey: utteranceID)
            guard context?.generation == playbackGeneration else { return }
            highlight = nil
            state = .idle
        }
    }
}

extension SpeechController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, audioPlayer === player else { return }
            finishAudioPlayback(success: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, audioPlayer === player else { return }
            finishAudioPlayback(success: false)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
