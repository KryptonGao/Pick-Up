import Foundation
import NaturalLanguage

protocol TextSegmenting: Sendable {
    func segment(_ text: String) -> [TextSegmentDraft]
}
struct TextSegmenter: TextSegmenting {
    private let targetCharacterCount = 320
    private let maximumSentencesPerSegment = 3

    func segment(_ text: String) -> [TextSegmentDraft] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        let blocks = paragraphRanges(in: text)
        var output: [TextSegmentDraft] = []

        for blockRange in blocks {
            let block = nsText.substring(with: blockRange)
            if isHeading(block) {
                output.append(
                    TextSegmentDraft(
                        order: output.count,
                        kind: .heading,
                        text: block,
                        sourceLocation: blockRange.location,
                        sourceLength: blockRange.length
                    )
                )
                continue
            }

            let sentenceRanges = sentences(in: block, offset: blockRange.location)
            guard !sentenceRanges.isEmpty else {
                output.append(
                    TextSegmentDraft(
                        order: output.count,
                        kind: .paragraph,
                        text: block,
                        sourceLocation: blockRange.location,
                        sourceLength: blockRange.length
                    )
                )
                continue
            }

            var pending: [NSRange] = []
            for range in sentenceRanges {
                let proposed = pending + [range]
                let union = unionRange(proposed)
                let proposedText = nsText.substring(with: union)
                let exceedsTarget = proposedText.count > targetCharacterCount
                let exceedsSentenceCount = proposed.count > maximumSentencesPerSegment

                if !pending.isEmpty && (exceedsTarget || exceedsSentenceCount) {
                    appendSegment(from: pending, source: nsText, to: &output)
                    pending = [range]
                } else {
                    pending = proposed
                }
            }
            appendSegment(from: pending, source: nsText, to: &output)
        }

        return output
    }

    private func paragraphRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let separator = try? NSRegularExpression(
            pattern: "(?:\\r\\n|\\r|\\n)[\\t ]*(?:\\r\\n|\\r|\\n)+"
        )
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = separator?.matches(in: text, range: fullRange) ?? []
        var ranges: [NSRange] = []
        var cursor = 0

        for match in matches {
            if match.range.location > cursor,
               let trimmed = trimmedRange(
                NSRange(location: cursor, length: match.range.location - cursor),
                in: nsText
               ) {
                ranges.append(trimmed)
            }
            cursor = NSMaxRange(match.range)
        }

        if cursor < nsText.length,
           let trimmed = trimmedRange(
            NSRange(location: cursor, length: nsText.length - cursor),
            in: nsText
           ) {
            ranges.append(trimmed)
        }
        return ranges
    }

    private func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange? {
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end,
              let scalar = UnicodeScalar(text.character(at: start)),
              whitespace.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(text.character(at: end - 1)),
              whitespace.contains(scalar) {
            end -= 1
        }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }

    private func isHeading(_ block: String) -> Bool {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
            return true
        }
        guard !trimmed.contains("\n"), !trimmed.contains("\r"), trimmed.count < 40 else {
            return false
        }
        return trimmed.range(of: #"[。！？!?；;：:]$"#, options: .regularExpression) == nil
    }

    private func sentences(in block: String, offset: Int) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = block
        let ranges = tokenizer.tokens(for: block.startIndex..<block.endIndex)
        return ranges.map {
            let local = NSRange($0, in: block)
            return NSRange(location: offset + local.location, length: local.length)
        }
    }

    private func appendSegment(
        from ranges: [NSRange],
        source: NSString,
        to output: inout [TextSegmentDraft]
    ) {
        guard !ranges.isEmpty else { return }
        let range = unionRange(ranges)
        output.append(
            TextSegmentDraft(
                order: output.count,
                kind: .paragraph,
                text: source.substring(with: range),
                sourceLocation: range.location,
                sourceLength: range.length
            )
        )
    }

    private func unionRange(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        return ranges.dropFirst().reduce(first, NSUnionRange)
    }
}
