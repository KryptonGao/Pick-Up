import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

typealias CaptureResult = Result<CapturePayload, CaptureIssue>

protocol SelectionCapturing: Sendable {
    func capture(from source: SourceContext) async -> CaptureResult
}

@MainActor
protocol ClipboardCapturing: AnyObject {
    func captureCurrent(source: SourceContext) -> CaptureResult
    func captureByCopying(source: SourceContext) async -> CaptureResult
}

extension SourceContext {
    @MainActor
    static func currentExternalApplication() -> SourceContext {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        return SourceContext(
            appName: application.localizedName ?? "未知来源",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowTitle: nil
        )
    }
}

final class AccessibilitySelectionCapturer: SelectionCapturing, @unchecked Sendable {
    nonisolated static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @MainActor
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func capture(from source: SourceContext) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(returning: captureSynchronously(from: source))
            }
        }
    }

    private nonisolated func captureSynchronously(from source: SourceContext) -> CaptureResult {
        guard Self.isTrusted else { return .failure(.permissionRequired) }
        guard source.processIdentifier != 0 else { return .failure(.unsupportedApp) }

        let application = AXUIElementCreateApplication(source.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.0)

        var enrichedSource = source
        if let window = copyElementAttribute(application, kAXFocusedWindowAttribute as CFString),
           let title = copyStringAttribute(window, kAXTitleAttribute as CFString),
           !title.isEmpty {
            enrichedSource.windowTitle = title
        }

        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedError == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .failure(issue(for: focusedError))
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedError == .success else {
            return .failure(issue(for: selectedError))
        }
        guard let text = selectedValue as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noSelection)
        }

        return .success(
            CapturePayload(text: text, source: enrichedSource, method: .accessibility)
        )
    }

    private nonisolated func copyElementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private nonisolated func copyStringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private nonisolated func issue(for error: AXError) -> CaptureIssue {
        switch error {
        case .apiDisabled:
            .permissionRequired
        case .cannotComplete:
            .targetUnresponsive
        case .attributeUnsupported, .notImplemented:
            .unsupportedApp
        case .noValue:
            .noSelection
        default:
            .unknown
        }
    }
}

@MainActor
final class PasteboardCaptureService: ClipboardCapturing {
    private let pasteboard: NSPasteboard
    private let copyTimeout: Duration
    private let lateCopyObservationWindow: Duration
    private let pollingInterval: Duration
    private let postCopyCommand: @MainActor () -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        copyTimeout: Duration = .milliseconds(800),
        lateCopyObservationWindow: Duration = .milliseconds(400),
        pollingInterval: Duration = .milliseconds(50),
        postCopyCommand: @escaping @MainActor () -> Bool = PasteboardCaptureService.postCopyCommand
    ) {
        self.pasteboard = pasteboard
        self.copyTimeout = copyTimeout
        self.lateCopyObservationWindow = lateCopyObservationWindow
        self.pollingInterval = pollingInterval
        self.postCopyCommand = postCopyCommand
    }

    func captureCurrent(source: SourceContext) -> CaptureResult {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.clipboardEmpty)
        }
        return .success(
            CapturePayload(text: text, source: source, method: .manualClipboard)
        )
    }

    func captureByCopying(source: SourceContext) async -> CaptureResult {
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let initialChangeCount = pasteboard.changeCount
        var copiedChangeCount: Int?

        defer {
            if let copiedChangeCount {
                _ = snapshot.restore(to: pasteboard, ifChangeCountIs: copiedChangeCount)
            }
        }

        guard postCopyCommand() else { return .failure(.unknown) }

        copiedChangeCount = await waitForChange(
            after: initialChangeCount,
            for: copyTimeout
        )

        if copiedChangeCount == nil {
            // The key event can be delivered after the target app's main thread
            // has had time to process it. Keep the request alive long enough to
            // observe that late write and restore the snapshot before returning.
            copiedChangeCount = await waitForChange(
                after: initialChangeCount,
                for: lateCopyObservationWindow
            )
        }

        guard copiedChangeCount != nil else {
            return .failure(.clipboardUnchanged)
        }

        let text = pasteboard.string(forType: .string)

        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.clipboardEmpty)
        }
        return .success(
            CapturePayload(text: text, source: source, method: .automaticClipboard)
        )
    }

    private func waitForChange(after initialChangeCount: Int, for duration: Duration) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            let changeCount = pasteboard.changeCount
            if changeCount != initialChangeCount {
                return changeCount
            }
            await sleepIgnoringCancellation(for: pollingInterval)
        }

        let finalChangeCount = pasteboard.changeCount
        return finalChangeCount == initialChangeCount ? nil : finalChangeCount
    }

    private func sleepIgnoringCancellation(for duration: Duration) async {
        let sleeper = Task.detached {
            try? await Task.sleep(for: duration)
        }
        await sleeper.value
    }

    private static func postCopyCommand() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { item.setData($1, forType: $0) }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
        return true
    }
}
