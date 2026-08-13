import CryptoKit
import Foundation

enum SpeechEngine: String, CaseIterable, Identifiable {
    case edge
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edge: "Microsoft Edge 在线语音"
        case .system: "macOS 本地语音"
        }
    }
}

struct EdgeVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String

    static let defaultVoiceID = "zh-CN-YunyangNeural"

    // A deliberately small, stable catalog. The Edge endpoint can change without notice;
    // keeping known short names here makes the picker available even when it is offline.
    static let catalog: [EdgeVoice] = [
        EdgeVoice(id: "zh-CN-YunyangNeural", name: "云扬", detail: "普通话 · 男声 · 新闻与旁白"),
        EdgeVoice(id: "zh-CN-YunxiNeural", name: "云希", detail: "普通话 · 男声 · 年轻自然"),
        EdgeVoice(id: "zh-CN-YunjianNeural", name: "云健", detail: "普通话 · 男声 · 沉稳有力"),
        EdgeVoice(id: "zh-CN-YunxiaNeural", name: "云夏", detail: "普通话 · 男声 · 少年感"),
        EdgeVoice(id: "zh-CN-XiaoxiaoNeural", name: "晓晓", detail: "普通话 · 女声 · 温暖自然"),
        EdgeVoice(id: "zh-CN-XiaoyiNeural", name: "晓伊", detail: "普通话 · 女声 · 明快亲切"),
        EdgeVoice(id: "zh-CN-liaoning-XiaobeiNeural", name: "晓北", detail: "辽宁口音 · 女声"),
        EdgeVoice(id: "zh-CN-shaanxi-XiaoniNeural", name: "晓妮", detail: "陕西口音 · 女声"),
        EdgeVoice(id: "zh-HK-HiuMaanNeural", name: "晓曼", detail: "粤语 · 女声"),
        EdgeVoice(id: "zh-HK-WanLungNeural", name: "云龙", detail: "粤语 · 男声"),
        EdgeVoice(id: "zh-TW-HsiaoChenNeural", name: "晓臻", detail: "台湾国语 · 女声"),
        EdgeVoice(id: "zh-TW-YunJheNeural", name: "云哲", detail: "台湾国语 · 男声")
    ]

    static func voice(for id: String) -> EdgeVoice {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}

enum EdgeTTSError: Error {
    case invalidRequest
    case connectionFailed
    case unexpectedResponse
    case noAudio
}

nonisolated protocol EdgeTTSSynthesizing: Sendable {
    func synthesize(text: String, voice: String, rate: Double) async throws -> Data
}

/// Native Swift implementation of the protocol used by the third-party edge-tts project.
/// This is an unofficial Microsoft Edge endpoint and may change without notice.
nonisolated struct EdgeTTSClient: EdgeTTSSynthesizing {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let endpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"

    func synthesize(text: String, voice: String, rate: Double) async throws -> Data {
        let chunks = Self.textChunks(text, maximumEscapedByteCount: 3_800)
        guard !chunks.isEmpty else { throw EdgeTTSError.invalidRequest }

        var result = Data()
        for chunk in chunks {
            try Task.checkCancellation()
            result.append(try await synthesizeChunk(text: chunk, voice: voice, rate: rate))
        }
        guard !result.isEmpty else { throw EdgeTTSError.noAudio }
        return result
    }

    private func synthesizeChunk(text: String, voice: String, rate: Double) async throws -> Data {
        let connectionID = Self.identifier()
        let query = [
            "TrustedClientToken=\(Self.trustedClientToken)",
            "ConnectionId=\(connectionID)",
            "Sec-MS-GEC=\(Self.securityToken())",
            "Sec-MS-GEC-Version=1-\(Self.chromiumVersion)"
        ].joined(separator: "&")
        guard let url = URL(string: "\(Self.endpoint)?\(query)") else {
            throw EdgeTTSError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("muid=\(Self.identifier().uppercased());", forHTTPHeaderField: "Cookie")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            try await socket.send(.string(Self.speechConfiguration))
            let ssml = Self.ssml(text: text, voice: voice, rate: rate)
            try await socket.send(.string(Self.ssmlMessage(ssml)))

            var audio = Data()
            while true {
                try Task.checkCancellation()
                let message = try await socket.receive()
                switch message {
                case .string(let value):
                    let (headers, _) = Self.parseTextMessage(value)
                    if headers["Path"] == "turn.end" {
                        guard !audio.isEmpty else { throw EdgeTTSError.noAudio }
                        return audio
                    }
                case .data(let value):
                    let (headers, payload) = try Self.parseBinaryMessage(value)
                    if headers["Path"] == "audio", !payload.isEmpty {
                        audio.append(payload)
                    }
                @unknown default:
                    throw EdgeTTSError.unexpectedResponse
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EdgeTTSError {
            throw error
        } catch {
            throw EdgeTTSError.connectionFailed
        }
    }

    static func textChunks(_ text: String, maximumEscapedByteCount: Int) -> [String] {
        guard maximumEscapedByteCount > 0 else { return [] }
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0

        for character in removeIncompatibleCharacters(text) {
            let escaped = escapeXML(String(character))
            let byteCount = escaped.utf8.count
            if currentBytes + byteCount > maximumEscapedByteCount, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += byteCount
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func edgeRate(for multiplier: Double) -> String {
        let bounded = min(max(multiplier, 0.5), 2.0)
        let percent = Int(((bounded - 1) * 100).rounded())
        return String(format: "%+d%%", percent)
    }

    static func ssml(text: String, voice: String, rate: Double) -> String {
        let voiceName = expandedVoiceName(voice)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>" +
            "<voice name='\(voiceName)'><prosody pitch='+0Hz' rate='\(edgeRate(for: rate))' volume='+0%'>" +
            escapeXML(removeIncompatibleCharacters(text)) +
            "</prosody></voice></speak>"
    }

    private static var speechConfiguration: String {
        "X-Timestamp:\(javascriptDate())\r\n" +
            "Content-Type:application/json; charset=utf-8\r\n" +
            "Path:speech.config\r\n\r\n" +
            #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"# +
            "\r\n"
    }

    private static func ssmlMessage(_ ssml: String) -> String {
        "X-RequestId:\(identifier())\r\n" +
            "Content-Type:application/ssml+xml\r\n" +
            "X-Timestamp:\(javascriptDate())Z\r\n" +
            "Path:ssml\r\n\r\n" + ssml
    }

    private static func parseTextMessage(_ value: String) -> ([String: String], Data) {
        guard let separator = value.range(of: "\r\n\r\n") else { return ([:], Data()) }
        let headers = parseHeaders(String(value[..<separator.lowerBound]))
        return (headers, Data(value[separator.upperBound...].utf8))
    }

    private static func parseBinaryMessage(_ value: Data) throws -> ([String: String], Data) {
        guard value.count >= 2 else { throw EdgeTTSError.unexpectedResponse }
        let headerLength = (Int(value[value.startIndex]) << 8) | Int(value[value.startIndex + 1])
        let headerStart = value.startIndex + 2
        let headerEnd = headerStart + headerLength
        guard headerEnd <= value.endIndex else { throw EdgeTTSError.unexpectedResponse }
        let headerData = value[headerStart..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw EdgeTTSError.unexpectedResponse
        }
        return (parseHeaders(headerString), Data(value[headerEnd..<value.endIndex]))
    }

    private static func parseHeaders(_ value: String) -> [String: String] {
        value.components(separatedBy: "\r\n").reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            result[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
    }

    private static func expandedVoiceName(_ shortName: String) -> String {
        let parts = shortName.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return shortName }
        let language = parts[0]
        var locale = "\(language)-\(parts[1])"
        var nameStart = 2
        if parts.count > 3 {
            locale += "-\(parts[2])"
            nameStart = 3
        }
        let name = parts[nameStart...].joined(separator: "-")
        return "Microsoft Server Speech Text to Speech Voice (\(locale), \(name))"
    }

    private static func removeIncompatibleCharacters(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            let value = scalar.value
            if value <= 8 || (11...12).contains(value) || (14...31).contains(value) {
                return " "
            }
            return String(scalar)
        }.joined())
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func securityToken(now: Date = .now) -> String {
        let windowsEpoch = 11_644_473_600.0
        var seconds = now.timeIntervalSince1970 + windowsEpoch
        seconds -= seconds.truncatingRemainder(dividingBy: 300)
        let ticks = Int64(seconds * 10_000_000)
        let input = Data("\(ticks)\(trustedClientToken)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02X", $0) }.joined()
    }

    private static func javascriptDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: .now)
    }

    private static var userAgent: String {
        let major = chromiumVersion.split(separator: ".").first ?? "143"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36 Edg/\(major).0.0.0"
    }
}
