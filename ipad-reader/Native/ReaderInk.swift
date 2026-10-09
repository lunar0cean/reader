import PencilKit

/// A pair owns one PKDrawing. Portrait clips one half; landscape shows both.
enum ReaderInk {
    static func key(left: String, right: String?) -> String { left + "|" + (right ?? "") }
    static func drawing(state: BookReadingState, left: String, right: String?, width: CGFloat) -> PKDrawing {
        if let data = state.spreadDrawings[key(left: left, right: right)], let drawing = try? PKDrawing(data: data) { return drawing }
        let first = state.drawings[left].flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        let second = right.flatMap { state.drawings[$0] }.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        return PKDrawing(strokes: first.strokes + second.transformed(using: CGAffineTransform(translationX: width, y: 0)).strokes)
    }
}
