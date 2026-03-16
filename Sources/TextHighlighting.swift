import SwiftUI

enum TextHighlighting {
    /// Highlight search terms in message text
    static func highlight(
        text: String,
        query: String,
        isRegex: Bool,
        isSent: Bool
    ) -> AttributedString {
        var attributed = AttributedString(text)

        guard !query.isEmpty else { return attributed }

        let highlightColor: Color = isSent
            ? Color.white.opacity(0.35)
            : Color.yellow.opacity(0.6)

        if isRegex {
            // Regex: highlight matches
            guard let regex = try? NSRegularExpression(pattern: query, options: .caseInsensitive) else {
                return attributed
            }
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text),
                      let attrRange = Range(range, in: attributed) else { continue }
                attributed[attrRange].backgroundColor = highlightColor
            }
        } else {
            // FTS: highlight individual terms
            let terms = query
                .replacingOccurrences(of: #"NOT\s+\w+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\bOR\\b", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "-", with: "")
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }

            for term in terms {
                guard let regex = try? NSRegularExpression(
                    pattern: NSRegularExpression.escapedPattern(for: term),
                    options: .caseInsensitive
                ) else { continue }
                let nsRange = NSRange(text.startIndex..., in: text)
                let matches = regex.matches(in: text, range: nsRange)
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: text),
                          let attrRange = Range(range, in: attributed) else { continue }
                    attributed[attrRange].backgroundColor = highlightColor
                }
            }
        }

        return attributed
    }

    /// Make URLs in an AttributedString clickable
    static func linkify(_ attributed: inout AttributedString) {
        let text = String(attributed.characters)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let matches = detector?.matches(in: text, range: nsRange) else { return }
        for match in matches.reversed() {
            guard let url = match.url,
                  let range = Range(match.range, in: text),
                  let attrRange = Range(range, in: attributed) else { continue }
            attributed[attrRange].link = url
        }
    }
}
