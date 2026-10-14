import Foundation
import UIKit
import PencilKit

// The same document schema is used by the native app and browser notebook.
// SVG carries a page snapshot in metadata; its visible ink is vector geometry.
struct NotebookPoint: Codable, Equatable {
    var x: Double; var y: Double
    var pressure: Double = 1
    var width: Double = 3; var height: Double = 3
    var time: Double = 0; var opacity: Double = 1
    var azimuth: Double = 0; var altitude: Double = .pi / 2
}
struct NotebookStroke: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var tool: String = "pen"; var color: String = "#202124"
    var points: [NotebookPoint]
    var transform: [Double] = [1, 0, 0, 1, 0, 0]
}
struct NotebookElement: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: String = "text"
    var x: Double = 80; var y: Double = 220
    var width: Double = 600; var height: Double = 140
    var text: String = ""; var fontSize: Double = 28
    var color: String = "#202124"; var bold: Bool = false
    var dataURI: String? = nil
    var citations: [ChatCitation]? = nil
    var characterID: String? = nil
    var replyID: String? = nil
    var provider: String? = nil
}
struct NotebookPage: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = "无标题页面"
    var created: String = ISO8601DateFormatter().string(from: Date())
    var width: Double = 1600; var height: Double = 2400
    var paper: String = "white"; var pattern: String = "blank"
    var strokes: [NotebookStroke] = []
    var elements: [NotebookElement] = []
    var inkData: Data? = nil
    var nativeStrokeCount: Int? = nil
    var strokeCount: Int { inkData == nil ? strokes.count : nativeStrokeCount ?? strokes.count }
    var size: CGSize { CGSize(width: width, height: height) }
    var drawing: PKDrawing {
        if let inkData, let value = try? PKDrawing(data: inkData) { return value }
        return PKDrawing(strokes: strokes.map { stroke in
            let points = stroke.points.map { point in
                PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: point.time,
                              size: CGSize(width: point.width, height: point.height), opacity: CGFloat(point.opacity),
                              force: CGFloat(point.pressure), azimuth: CGFloat(point.azimuth), altitude: CGFloat(point.altitude))
            }
            let t = stroke.transform
            return PKStroke(ink: PKInk(stroke.tool == "marker" ? .marker : stroke.tool == "pencil" ? .pencil : .pen, color: UIColor(notebookHex: stroke.color)),
                            path: PKStrokePath(controlPoints: points, creationDate: Date()),
                            transform: CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5]), mask: nil)
        })
    }
    mutating func capture(_ drawing: PKDrawing) {
        inkData = drawing.dataRepresentation()
        nativeStrokeCount = drawing.strokes.count
        strokes = drawing.strokes.map { stroke in
            let t = stroke.transform
            return NotebookStroke(tool: stroke.ink.inkType == .marker ? "marker" : stroke.ink.inkType == .pencil ? "pencil" : "pen",
                                  color: stroke.ink.color.notebookHex,
                                  points: stroke.path.map { p in NotebookPoint(x: p.location.x, y: p.location.y, pressure: p.force,
                                                                             width: p.size.width, height: p.size.height, time: p.timeOffset,
                                                                             opacity: p.opacity, azimuth: p.azimuth, altitude: p.altitude) },
                                  transform: [t.a, t.b, t.c, t.d, t.tx, t.ty])
        }
        grow(to: drawing.bounds.maxX + 350, y: drawing.bounds.maxY + 350)
    }
    // The editable native drawing is the source of truth while writing.
    // Sampling every old stroke again is reserved for portable export.
    mutating func captureNative(_ drawing: PKDrawing, data: Data? = nil) {
        inkData = data ?? drawing.dataRepresentation(); nativeStrokeCount = drawing.strokes.count
        strokes = []
        if !drawing.bounds.isEmpty { grow(to: drawing.bounds.maxX + 350, y: drawing.bounds.maxY + 350) }
    }
    mutating func grow(to x: Double, y: Double) {
        // Logical extents grow only to the right/bottom. No bitmap is allocated
        // for the whole page, and existing ink never moves when it grows.
        if x > width { width = min(10_000_000, ceil(x / 1024) * 1024) }
        if y > height { height = min(10_000_000, ceil(y / 1024) * 1024) }
    }
}
struct NotebookSection: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = "新分区 1"
    var pages: [NotebookPage] = [NotebookPage()]
}
struct NotebookBook: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String = "我的笔记本"
    var color: String = "#8030A7"
    var sections: [NotebookSection] = [NotebookSection()]
    var lastSectionID: String? = nil
    var lastPageID: String? = nil
    var customCover: Data? = nil
}
struct NotebookDocument: Codable {
    var engine: String = "yejian-notebook-v1"
    var version: Int = 1
    var notebooks: [NotebookBook]
    var notebookID: String; var sectionID: String; var pageID: String

    mutating func removeBook(_ id: String) {
        notebooks.removeAll { $0.id == id }
        if notebookID == id { normalizeSelection() }
    }
    mutating func normalizeSelection() {
        let book = notebooks.first { $0.id == notebookID } ?? notebooks.first
        let section = book?.sections.first { $0.id == sectionID } ?? book?.sections.first
        let page = section?.pages.first { $0.id == pageID } ?? section?.pages.first
        notebookID = book?.id ?? ""; sectionID = section?.id ?? ""; pageID = page?.id ?? ""
    }

    /// Produce portable point lists only for an explicit export, never per stroke.
    func exportSnapshot() -> NotebookDocument {
        var snapshot = self
        for b in snapshot.notebooks.indices {
            for s in snapshot.notebooks[b].sections.indices {
                for p in snapshot.notebooks[b].sections[s].pages.indices {
                    let drawing = snapshot.notebooks[b].sections[s].pages[p].drawing
                    if snapshot.notebooks[b].sections[s].pages[p].inkData != nil && snapshot.notebooks[b].sections[s].pages[p].strokes.isEmpty {
                        snapshot.notebooks[b].sections[s].pages[p].capture(drawing)
                    }
                }
            }
        }
        return snapshot
    }
}
struct NotebookPageTransfer: Codable {
    var engine: String = "yejian-notebook-page-v1"
    var version: Int = 1
    var page: NotebookPage
}

extension UIColor {
    convenience init(notebookHex: String) {
        let value = UInt32(notebookHex.dropFirst(), radix: 16) ?? 0x202124
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var notebookHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

enum NotebookCodec {
    static func validate(_ page: NotebookPage) throws {
        func number(_ n: Double, _ low: Double = 0, _ high: Double = 10_000_000) -> Bool { n.isFinite && n >= low && n <= high }
        func color(_ text: String) -> Bool { text.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }
        guard !page.id.isEmpty, page.title.count <= 500, number(page.width, 600), number(page.height, 600),
              ["white", "cream", "dark"].contains(page.paper), ["blank", "lined", "grid"].contains(page.pattern),
              page.strokes.count <= 100_000, page.elements.count <= 10_000,
              Set(page.strokes.map(\.id)).count == page.strokes.count, Set(page.elements.map(\.id)).count == page.elements.count else {
            throw ReaderFileError.invalid("笔记页的尺寸或内容无效。")
        }
        var count = 0
        for s in page.strokes {
            count += s.points.count
            guard ["pen", "marker", "pencil"].contains(s.tool), color(s.color), !s.points.isEmpty,
                  s.transform.count == 6, s.transform.allSatisfy({ number($0, -10_000_000) }), count <= 2_000_000,
                  s.points.allSatisfy({ number($0.x) && number($0.y) && number($0.pressure, 0, 20)
                    && number($0.width, 0.01, 256) && number($0.height, 0.01, 256) && number($0.time)
                    && number($0.opacity, 0, 1) && number($0.azimuth, -100, 100) && number($0.altitude, -100, 100) }) else {
                throw ReaderFileError.invalid("笔迹采样或压感数据无效。")
            }
        }
        for e in page.elements {
            guard ["text", "image"].contains(e.kind), number(e.x), number(e.y), number(e.width, 20, 100_000),
                  number(e.height, 20, 100_000), number(e.fontSize, 12, 128), color(e.color), e.text.count <= 100_000 else {
                throw ReaderFileError.invalid("文字或图片的位置无效。")
            }
            if e.kind == "image" {
                guard let data = imageData(e.dataURI), data.count <= 10 * 1024 * 1024, UIImage(data: data) != nil else {
                    throw ReaderFileError.invalid("笔记图片无效；仅支持内嵌位图。")
                }
            }
        }
        if let ink = page.inkData { guard ink.count <= 100 * 1024 * 1024, (try? PKDrawing(data: ink)) != nil else { throw ReaderFileError.invalid("原生笔迹数据损坏。") } }
    }
    static func validate(_ document: NotebookDocument) throws {
        guard document.engine == "yejian-notebook-v1", document.version == 1,
              document.notebooks.count <= 500 else { throw ReaderFileError.invalid("不是有效的笔记本备份。") }
        if document.notebooks.isEmpty {
            guard document.notebookID.isEmpty, document.sectionID.isEmpty, document.pageID.isEmpty else { throw ReaderFileError.invalid("空书库的笔记选择无效。") }
            return
        }
        var ids = Set<String>(), pages = 0
        for book in document.notebooks {
            guard !book.id.isEmpty, ids.insert(book.id).inserted, !book.sections.isEmpty, book.title.count <= 500,
                  book.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw ReaderFileError.invalid("笔记本结构无效。") }
            for section in book.sections {
                guard !section.id.isEmpty, ids.insert(section.id).inserted, !section.pages.isEmpty, section.title.count <= 500 else { throw ReaderFileError.invalid("分区结构无效。") }
                for page in section.pages { pages += 1; guard pages <= 10_000, ids.insert(page.id).inserted else { throw ReaderFileError.invalid("笔记页重复或过多。") }; try validate(page) }
            }
        }
        guard let book = document.notebooks.first(where: { $0.id == document.notebookID }),
              let section = book.sections.first(where: { $0.id == document.sectionID }), section.pages.contains(where: { $0.id == document.pageID }) else {
            throw ReaderFileError.invalid("当前笔记页不存在。")
        }
    }
    static func imageData(_ uri: String?) -> Data? {
        guard let uri, uri.range(of: "^data:image/(png|jpeg|gif|webp);base64,", options: .regularExpression) != nil,
              let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }
}
