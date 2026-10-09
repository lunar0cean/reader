import Foundation

struct SpeechChunk: Equatable { let text: String; let range: NSRange }
struct SpeechMark: Equatable { let sourceID: String; let range: NSRange }

enum SpeechText {
    // Ranges refer to the untouched UTF-16 source, including attachment slots.
    // Normalization is only for synthesis and must never move the highlight.
    static func chunks(_ text: String, from offset: Int = 0) -> [SpeechChunk] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var result: [SpeechChunk] = [], start = max(0, min(offset, source.length))
        if start < source.length { start = source.rangeOfComposedCharacterSequence(at: start).location }
        var end = start
        let boundaries = CharacterSet(charactersIn: "。！？!?；;\n")
        while end < source.length {
            let character = source.rangeOfComposedCharacterSequence(at: end)
            let value = source.substring(with: character); end = NSMaxRange(character)
            if value.unicodeScalars.contains(where: { boundaries.contains($0) }) || end - start >= 120 || end == source.length {
                let range = NSRange(location: start, length: end - start)
                let spoken = source.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty { result.append(SpeechChunk(text: spoken, range: range)) }
                start = end
            }
        }
        return result
    }
    static func language(_ text: String) -> String { text.range(of: "[ぁ-んァ-ヶ]", options: .regularExpression) == nil ? "zh" : "ja" }
}
