import Foundation
import SwiftData

enum CaptureMethod: String, Codable, Sendable {
    case accessibility
    case automaticClipboard
    case manualClipboard

    var title: String {
        switch self {
        case .accessibility: "辅助功能选区"
        case .automaticClipboard: "复制备用流程"
        case .manualClipboard: "剪贴板"
        }
    }
}

enum SegmentKind: String, Codable, Sendable {
    case heading
    case paragraph
}

struct SourceContext: Codable, Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    var windowTitle: String?

    static let unknown = SourceContext(
        appName: "未知来源",
        bundleIdentifier: nil,
        processIdentifier: 0,
        windowTitle: nil
    )
}

struct CapturePayload: Equatable, Sendable {
    let text: String
    let source: SourceContext
    let method: CaptureMethod
}

struct CaptureDraft: Equatable, Sendable {
    let text: String
    let source: SourceContext
    let method: CaptureMethod
    var wasTruncated: Bool

    var characterCount: Int { text.count }
}

enum CaptureIssue: Error, Equatable, Sendable {
    case permissionRequired
    case noSelection
    case unsupportedApp
    case targetUnresponsive
    case clipboardEmpty
    case clipboardUnchanged
    case shortcutMissing
    case speechUnavailable
    case onlineSpeechUnavailable
    case unknown

    var title: String {
        switch self {
        case .permissionRequired: "需要辅助功能权限"
        case .noSelection: "没有读取到选中的文字"
        case .unsupportedApp: "当前 App 不支持直接取词"
        case .targetUnresponsive: "当前 App 暂时没有响应"
        case .clipboardEmpty: "剪贴板中没有文字"
        case .clipboardUnchanged: "没有检测到新的复制内容"
        case .shortcutMissing: "请先录制快捷键"
        case .speechUnavailable: "暂时无法朗读"
        case .onlineSpeechUnavailable: "在线语音暂时不可用"
        case .unknown: "暂时无法处理这段文字"
        }
    }

    var message: String {
        switch self {
        case .permissionRequired:
            "Pick Up 只在你主动按下快捷键时读取当前选区，不会持续监控屏幕或键盘。你也可以不授权，改用手动复制。"
        case .noSelection:
            "请回到原 App 重新选择一段文字，或先复制文字，再从菜单栏选择“从剪贴板新建”。"
        case .unsupportedApp:
            "可以先在原 App 按 Command-C，然后从菜单栏选择“从剪贴板新建”。"
        case .targetUnresponsive:
            "请稍后重试；当前阅读内容仍然安全保留。"
        case .clipboardEmpty:
            "请先复制一段文字，再试一次。"
        case .clipboardUnchanged:
            "自动复制没有获得新内容。请手动复制后使用剪贴板入口。"
        case .shortcutMissing:
            "快捷键不会被预先占用，请录制一个适合自己的组合键。"
        case .speechUnavailable:
            "请检查系统声音输出，或稍后重新播放。"
        case .onlineSpeechUnavailable:
            "请检查网络后重试，或改用 macOS 本地语音。Microsoft Edge 在线语音可能会临时调整接口。"
        case .unknown:
            "可以重试，或改用剪贴板流程。现有阅读内容不会被删除。"
        }
    }
}

enum AppPhase: Equatable {
    case onboarding
    case idle
    case capturing
    case preview
    case overLimit
    case reader
    case failure(CaptureIssue)
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case focused
    case continuous
    case highlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focused: "逐段"
        case .continuous: "连续"
        case .highlights: "重点"
        }
    }
}

enum ReadingBackground: String, CaseIterable, Identifiable {
    case system
    case warm
    case softGray
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统"
        case .warm: "暖色纸张"
        case .softGray: "柔和灰"
        case .dark: "深色"
        }
    }
}

struct TextSegmentDraft: Equatable, Sendable {
    let order: Int
    let kind: SegmentKind
    let text: String
    let sourceLocation: Int
    let sourceLength: Int
}

@Model
final class ReadingDocument {
    @Attribute(.unique) var id: UUID
    var originalText: String
    var sourceAppName: String
    var sourceBundleIdentifier: String?
    var sourceWindowTitle: String?
    var captureMethodRawValue: String
    var capturedAt: Date
    var updatedAt: Date
    var currentSegmentIndex: Int
    var wasTruncated: Bool
    var isActive: Bool = true
    @Relationship(deleteRule: .cascade) var segments: [ReadingSegment]

    init(
        id: UUID = UUID(),
        originalText: String,
        source: SourceContext,
        captureMethod: CaptureMethod,
        wasTruncated: Bool,
        segments: [ReadingSegment]
    ) {
        self.id = id
        self.originalText = originalText
        self.sourceAppName = source.appName
        self.sourceBundleIdentifier = source.bundleIdentifier
        self.sourceWindowTitle = source.windowTitle
        self.captureMethodRawValue = captureMethod.rawValue
        self.capturedAt = .now
        self.updatedAt = .now
        self.currentSegmentIndex = 0
        self.wasTruncated = wasTruncated
        self.isActive = true
        self.segments = segments
    }

    var captureMethod: CaptureMethod {
        CaptureMethod(rawValue: captureMethodRawValue) ?? .manualClipboard
    }

    var orderedSegments: [ReadingSegment] {
        segments.sorted { $0.order < $1.order }
    }

    var hasProgressOrHighlights: Bool {
        currentSegmentIndex > 0 || segments.contains(where: \.isHighlighted)
    }
}

@Model
final class ReadingSegment {
    @Attribute(.unique) var id: UUID
    var order: Int
    var kindRawValue: String
    var text: String
    var sourceLocation: Int
    var sourceLength: Int
    var isHighlighted: Bool

    init(
        id: UUID = UUID(),
        order: Int,
        kind: SegmentKind,
        text: String,
        sourceLocation: Int,
        sourceLength: Int,
        isHighlighted: Bool = false
    ) {
        self.id = id
        self.order = order
        self.kindRawValue = kind.rawValue
        self.text = text
        self.sourceLocation = sourceLocation
        self.sourceLength = sourceLength
        self.isHighlighted = isHighlighted
    }

    var kind: SegmentKind {
        SegmentKind(rawValue: kindRawValue) ?? .paragraph
    }
}
