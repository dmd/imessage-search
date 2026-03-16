import Foundation

enum AttributedBodyParser {
    /// Extract plain text from an iMessage attributedBody binary blob
    static func extractText(from data: Data) -> String? {
        let marker: [UInt8] = [0x01, 0x2B]
        guard let markerRange = data.firstRange(of: Data(marker)) else {
            return nil
        }

        var pos = markerRange.upperBound
        guard pos < data.endIndex else { return nil }

        let lengthByte = data[pos]
        pos = data.index(after: pos)

        let textLength: Int
        if lengthByte < 0x80 {
            textLength = Int(lengthByte)
        } else {
            let numBytes = Int(lengthByte - 0x80) + 1
            guard let endPos = data.index(pos, offsetBy: numBytes, limitedBy: data.endIndex) else {
                return nil
            }
            let lengthData = data[pos..<endPos]
            var value = 0
            for (i, byte) in lengthData.enumerated() {
                value |= Int(byte) << (8 * i)
            }
            textLength = value
            pos = endPos
        }

        let textData: Data
        if let textEnd = data.index(pos, offsetBy: textLength, limitedBy: data.endIndex),
           textEnd <= data.endIndex {
            textData = data[pos..<textEnd]
        } else {
            // Fallback: search for end marker
            let endMarker: [UInt8] = [0x86, 0x84]
            if let endRange = data[pos...].firstRange(of: Data(endMarker)) {
                textData = data[pos..<endRange.lowerBound]
            } else {
                return nil
            }
        }

        guard let text = String(data: textData, encoding: .utf8)?
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
