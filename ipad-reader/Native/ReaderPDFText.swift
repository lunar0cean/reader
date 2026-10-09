import PDFKit

/// Never pass NSNotFound or a zero-character range into PDFKit selection.
enum ReaderPDFText {
    static func source(_ page: PDFPage) -> String {
        // Build PDFKit's character layout before extracting text so reading,
        // copying and highlight ranges refer to the same character cache.
        _ = page.numberOfCharacters
        return page.string ?? ""
    }
    static func range(count: Int, from: Int, to: Int) -> NSRange? {
        guard count > 0, from >= 0, to >= 0, from < count, to < count else { return nil }
        return NSRange(location: min(from, to), length: max(from, to) - min(from, to) + 1)
    }
    static func word(_ page: PDFPage, at point: CGPoint) -> PDFSelection? {
        guard point.x.isFinite, point.y.isFinite, page.numberOfCharacters > 0,
              !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let index = page.characterIndex(at: point)
        guard range(count: page.numberOfCharacters, from: index, to: index) != nil else { return nil }
        // PDFKit can pick the nearest word even when pressing a blank/image area.
        guard page.characterBounds(at: index).insetBy(dx: -5, dy: -5).contains(point),
              let word = page.selectionForWord(at: point),
              !(word.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return word
    }
}
