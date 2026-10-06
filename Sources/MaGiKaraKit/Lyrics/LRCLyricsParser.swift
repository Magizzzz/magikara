import Foundation

/// Converts LRCLIB lyric payloads to ordered text lines. It intentionally returns no timings.
public enum LRCLyricsParser {
    private static let timestampPattern = #"\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]"#
    private static let enhancedTimestampPattern = #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#
    private static let metadataPattern = #"^\s*\[(?:ar|ti|al|by|re|ve|offset|length|tool):[^\]]*\]\s*$"#
    private static let leadingTimestampsPattern = #"^\s*(?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+"#

    /// Prefer synchronized lyrics for their explicit line/repetition structure, but discard every timestamp.
    public static func text(synchronized: String?, plain: String?) -> (text: String, source: LyricsTextSource)? {
        if let synchronized, let text = text(fromSynchronized: synchronized) {
            return (text, .synchronized)
        }
        if let plain, let text = text(fromPlain: plain) {
            return (text, .plain)
        }
        return nil
    }

    public static func text(fromSynchronized raw: String) -> String? {
        let timestampRegex = try? NSRegularExpression(pattern: timestampPattern)
        let enhancedRegex = try? NSRegularExpression(pattern: enhancedTimestampPattern)
        let metadataRegex = try? NSRegularExpression(pattern: metadataPattern, options: [.caseInsensitive])
        let leadingRegex = try? NSRegularExpression(pattern: leadingTimestampsPattern)
        var output: [String] = []

        for originalLine in normalizedLines(raw) {
            let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let wholeRange = NSRange(line.startIndex..., in: line)
            if metadataRegex?.firstMatch(in: line, range: wholeRange) != nil { continue }

            let leadingRange = leadingRegex?.firstMatch(in: line, range: wholeRange)?.range
            let repeatCount: Int
            if let leadingRange {
                repeatCount = timestampRegex?.matches(in: line,
                                                     range: leadingRange).count ?? 1
            } else {
                repeatCount = 1
            }

            var text = timestampRegex?.stringByReplacingMatches(in: line,
                                                                  range: wholeRange,
                                                                  withTemplate: "") ?? line
            let textRange = NSRange(text.startIndex..., in: text)
            text = enhancedRegex?.stringByReplacingMatches(in: text,
                                                            range: textRange,
                                                            withTemplate: "") ?? text
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Multiple leading time tags mean the same lyric is sung at multiple positions.
            output.append(contentsOf: repeatElement(text, count: max(1, repeatCount)))
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    public static func text(fromPlain raw: String) -> String? {
        let lines = normalizedLines(raw).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func normalizedLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}
