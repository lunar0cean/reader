import Foundation
import PencilKit

enum NotebookSVG {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
    static func outline(_ points: [NotebookPoint]) -> String {
        guard let first = points.first else { return "" }
        if points.count == 1 { return "M \(number(first.x - first.width / 2)) \(number(first.y)) a \(number(first.width / 2)) \(number(first.height / 2)) 0 1 0 \(number(first.width)) 0 a \(number(first.width / 2)) \(number(first.height / 2)) 0 1 0 -\(number(first.width)) 0 Z" }
        var left = [String](), right = [String]()
        for i in points.indices {
            let p = points[i], before = points[max(0, i - 1)], after = points[min(points.count - 1, i + 1)]
            let dx = after.x - before.x, dy = after.y - before.y, length = max(0.0001, hypot(dx, dy))
            let nx = -dy / length, ny = dx / length
            // Elliptic nib widths preserve the pressure-dependent size samples.
            let r = max(0.05, hypot(p.width * nx, p.height * ny) / 2)
            left.append("\(number(p.x + nx * r)) \(number(p.y + ny * r))")
            right.append("\(number(p.x - nx * r)) \(number(p.y - ny * r))")
        }
        return "M " + left.joined(separator: " L ") + " L " + right.reversed().joined(separator: " L ") + " Z"
    }
    static func export(_ source: NotebookPage) throws -> Data {
        var page = source
        // A materialized point list already has stable editable stroke IDs.
        if page.inkData != nil && page.strokes.isEmpty { page.capture(page.drawing) }
        try NotebookCodec.validate(page)
        let transfer = try JSONEncoder().encode(NotebookPageTransfer(page: page)).base64EncodedString()
        let paper = page.paper == "dark" ? "#202124" : page.paper == "cream" ? "#F8F1DF" : "#FFFFFF"
        let ink = page.paper == "dark" ? "#EEEEEE" : "#202124"
        let w = number(page.width), h = number(page.height)
        var parts = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">",
                     "<metadata id=\"yejian-notebook\">\(transfer)</metadata>",
                     "<defs><pattern id=\"paper-grid\" width=\"32\" height=\"32\" patternUnits=\"userSpaceOnUse\"><path d=\"M 0 32 H 32\(page.pattern == "grid" ? " M 32 0 V 32" : "")\" fill=\"none\" stroke=\"#A5A5A5\" stroke-opacity=\"0.22\"/></pattern></defs>",
                     "<rect width=\"100%\" height=\"100%\" fill=\"\(paper)\"/>"]
        if page.pattern != "blank" { parts.append("<rect width=\"100%\" height=\"100%\" fill=\"url(#paper-grid)\"/>") }
        parts.append("<text x=\"64\" y=\"100\" font-family=\"sans-serif\" font-size=\"48\" fill=\"\(ink)\">\(escape(page.title))</text><path d=\"M 64 128 H 1100\" stroke=\"#BBBBBB\"/><text x=\"64\" y=\"163\" font-family=\"sans-serif\" font-size=\"18\" fill=\"#888888\">\(escape(String(page.created.prefix(10))))</text>")
        for e in page.elements {
            if e.kind == "image", let uri = e.dataURI { parts.append("<image x=\"\(number(e.x))\" y=\"\(number(e.y))\" width=\"\(number(e.width))\" height=\"\(number(e.height))\" href=\"\(escape(uri))\" preserveAspectRatio=\"xMidYMid meet\"/>") }
            else {
                parts.append("<text fill=\"\(e.color)\" font-size=\"\(number(e.fontSize))\" font-weight=\"\(e.bold ? 700 : 400)\" font-family=\"sans-serif\">")
                for (i, line) in e.text.components(separatedBy: "\n").enumerated() { parts.append("<tspan x=\"\(number(e.x))\" y=\"\(number(e.y + e.fontSize + Double(i) * e.fontSize * 1.4))\">\(escape(line))</tspan>") }
                parts.append("</text>")
            }
        }
        // Use PencilKit's interpolated centerline for the shareable outline.
        // Metadata retains the original force, timing and editable native data.
        let drawings = page.drawing.strokes
        for (index, s) in page.strokes.enumerated() {
            let points: [NotebookPoint]
            if drawings.indices.contains(index) {
                points = drawings[index].path.interpolatedPoints(by: .distance(2)).prefix(200_000).map {
                    NotebookPoint(x: $0.location.x, y: $0.location.y, width: $0.size.width, height: $0.size.height, opacity: $0.opacity)
                }
            } else { points = s.points }
            let matrix = s.transform.map(number).joined(separator: " ")
            let opacity = s.tool == "marker" ? 0.28 : max(0.05, s.points.map(\.opacity).reduce(0, +) / Double(s.points.count))
            parts.append("<g fill=\"\(s.color)\" opacity=\"\(number(opacity))\" transform=\"matrix(\(matrix))\"><path d=\"\(outline(points))\"/>")
            for p in [points.first, points.last].compactMap({ $0 }) { parts.append("<ellipse cx=\"\(number(p.x))\" cy=\"\(number(p.y))\" rx=\"\(number(p.width / 2))\" ry=\"\(number(p.height / 2))\"/>") }
            parts.append("</g>")
        }
        parts.append("</svg>")
        return Data(parts.joined(separator: "\n").utf8)
    }
    static func restore(_ data: Data) throws -> NotebookPage {
        guard data.count <= 150 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE|<!ENTITY", options: [.regularExpression, .caseInsensitive]) == nil else { throw ReaderFileError.invalid("SVG 文件无效。") }
        let delegate = Metadata(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let payload = Data(base64Encoded: delegate.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ReaderFileError.invalid("该 SVG 没有阅读器可编辑笔记数据。") }
        let value = try JSONDecoder().decode(NotebookPageTransfer.self, from: payload)
        guard value.engine == "yejian-notebook-page-v1", value.version == 1 else { throw ReaderFileError.invalid("SVG 笔记版本不受支持。") }
        try NotebookCodec.validate(value.page)
        return value.page
    }
    private final class Metadata: NSObject, XMLParserDelegate {
        var collecting = false; var value = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { if name == "metadata" && attributes["id"] == "yejian-notebook" { collecting = true } }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { value += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if name == "metadata" { collecting = false } }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}
