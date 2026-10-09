import UIKit
import ZIPFoundation

enum ReaderSlides {
    static let version = 2
    static func book(data: Data, name: String) throws -> ReaderBook {
        ReaderFont.register()
        let archive = try Archive(data: data, accessMode: .read)
        var total: UInt64 = 0, count = 0
        for entry in archive {
            count += 1
            guard count <= 10000, entry.uncompressedSize <= 20 * 1024 * 1024, total <= 100 * 1024 * 1024 - entry.uncompressedSize else { throw ReaderFileError.invalid("PPTX 解压内容过大。") }
            total += entry.uncompressedSize
        }
        func read(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file else { throw ReaderFileError.invalid("PPTX 缺少 \(path)") }
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }; return bytes
        }
        func relationships(_ path: String) -> [String: String] {
            let parts = path.split(separator: "/")
            let rel = parts.dropLast().joined(separator: "/") + "/_rels/" + String(parts.last ?? "") + ".rels"
            guard let bytes = try? read(rel), let xml = try? ReaderXML.parse(bytes) else { return [:] }
            return Dictionary(xml.descendants("Relationship").compactMap { node -> (String, String)? in
                guard node.attributes["TargetMode"] != "External", let id = node.attributes["Id"], let target = node.attributes["Target"], let resolved = ReaderImport.resourcePath(target, from: path) else { return nil }
                return (id, resolved)
            }, uniquingKeysWith: { first, _ in first })
        }
        let presentation = try ReaderXML.parse(read("ppt/presentation.xml")), links = relationships("ppt/presentation.xml")
        let slides = presentation.descendants("sldId").compactMap { $0.attributes["r:id"].flatMap { links[$0] } }
        guard !slides.isEmpty, slides.count <= 2000 else { throw ReaderFileError.invalid("PPTX 没有幻灯片或超过 2000 页。") }
        let sz = presentation.descendants("sldSz").first
        let size = CGSize(width: (Double(sz?.attributes["cx"] ?? "") ?? 12192000) / 12700, height: (Double(sz?.attributes["cy"] ?? "") ?? 6858000) / 12700)
        guard size.width >= 100, size.height >= 100, size.width <= 4000, size.height <= 4000 else { throw ReaderFileError.invalid("PPTX 页面尺寸无效。") }
        let renderer = SlideRenderer(read: read, relationships: relationships)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { output in
            for path in slides { output.beginPage(); renderer.draw(path, context: output.cgContext, size: size) }
        }
        var book = try ReaderImport.pdf(data: pdf, name: (name as NSString).deletingPathExtension + ".pdf")
        book.format = "PPTX"; book.original = data; book.originalName = name; book.renderedPDF = pdf; book.slideRendererVersion = version
        book.importWarnings = Array(renderer.warnings).sorted(); return book
    }
}

private final class SlideRenderer {
    let read: (String) throws -> Data
    let relationships: (String) -> [String: String]
    var warnings = Set<String>()
    var colors: [String: UIColor] = [:], fonts: [String: String] = [:], colorMap: [String: String] = [:]
    var master: ReaderXML?, layout: ReaderXML?
    init(read: @escaping (String) throws -> Data, relationships: @escaping (String) -> [String: String]) { self.read = read; self.relationships = relationships }
    func xml(_ path: String?) -> ReaderXML? { guard let path, let bytes = try? read(path) else { return nil }; return try? ReaderXML.parse(bytes) }
    func draw(_ path: String, context: CGContext, size: CGSize) {
        guard let slide = xml(path), let tree = slide.descendants("spTree").first else { return }
        let rels = relationships(path)
        let layoutPath = rels.values.first { $0.contains("slideLayouts/") }, layoutRels = layoutPath.map(relationships) ?? [:]
        let masterPath = layoutRels.values.first { $0.contains("slideMasters/") }, masterRels = masterPath.map(relationships) ?? [:]
        layout = xml(layoutPath); master = xml(masterPath)
        let theme = xml(masterRels.values.first { $0.contains("theme/") })
        colorMap = master?.descendants("clrMap").first?.attributes ?? [:]
        colors = ["lt1": .white, "dk1": .black, "lt2": .white, "dk2": .black]
        for item in theme?.descendants("clrScheme").first?.children ?? [] {
            if let value = item.descendants("srgbClr").first?.attributes["val"] ?? item.descendants("sysClr").first?.attributes["lastClr"] { colors[item.name] = UIColor(notebookHex: "#" + value) }
        }
        fonts = [:]
        for (name, prefix) in [("majorFont", "+mj"), ("minorFont", "+mn")] {
            for (kind, suffix) in [("latin", "-lt"), ("ea", "-ea"), ("cs", "-cs")] {
                if let family = theme?.descendants(name).first?.children.first(where: { $0.name == kind })?.attributes["typeface"], !family.isEmpty { fonts[prefix + suffix] = family }
            }
        }
        let bg = slide.descendants("bg").first ?? layout?.descendants("bg").first ?? master?.descendants("bg").first
        (color(bg?.descendants("solidFill").first) ?? .white).setFill(); context.fill(CGRect(origin: .zero, size: size))
        let matrix = CGAffineTransform(scaleX: 1 / 12700, y: 1 / 12700)
        for (base, basePath) in [(master, masterPath), (layout, layoutPath)] {
            if let base, let basePath, let baseTree = base.descendants("spTree").first { children(baseTree, matrix: matrix, rels: relationships(basePath), context: context, skipPlaceholders: true, depth: 0) }
        }
        children(tree, matrix: matrix, rels: rels, context: context, skipPlaceholders: false, depth: 0)
    }
    func color(_ fill: ReaderXML?) -> UIColor? {
        guard let node = fill?.children.first(where: { ["srgbClr", "schemeClr", "sysClr"].contains($0.name) }) else { return nil }
        var value: UIColor
        if node.name == "schemeClr" { let name = node.attributes["val"] ?? "dk1"; value = colors[colorMap[name] ?? (name == "bg1" ? "lt1" : name == "tx1" ? "dk1" : name)] ?? .black }
        else { value = UIColor(notebookHex: "#" + (node.attributes["lastClr"] ?? node.attributes["val"] ?? "000000")) }
        if let alpha = node.descendants("alpha").first?.attributes["val"], let opacity = Double(alpha) { value = value.withAlphaComponent(CGFloat(max(0, min(1, opacity / 100000)))) }; return value
    }
    func placeholder(_ shape: ReaderXML, in base: ReaderXML?) -> ReaderXML? {
        guard let ph = shape.descendants("ph").first else { return nil }
        return base?.descendants("sp").first { other in
            guard let candidate = other.descendants("ph").first else { return false }
            return (ph.attributes["idx"] ?? "0") == (candidate.attributes["idx"] ?? "0") && (ph.attributes["type"] ?? "body") == (candidate.attributes["type"] ?? "body")
        }
    }
    func transform(_ shape: ReaderXML) -> ReaderXML? { shape.children.first(where: { ["spPr", "grpSpPr"].contains($0.name) })?.children.first(where: { $0.name == "xfrm" }) ?? shape.children.first(where: { $0.name == "xfrm" }) }
    func number(_ node: ReaderXML?, _ attr: String, _ fallback: CGFloat = 0) -> CGFloat { CGFloat(Double(node?.attributes[attr] ?? "") ?? Double(fallback)) }
    func rect(_ x: ReaderXML?, matrix: CGAffineTransform) -> CGRect? {
        guard let x, let off = x.children.first(where: { $0.name == "off" }), let ext = x.children.first(where: { $0.name == "ext" }) else { return nil }
        let raw = CGRect(x: number(off, "x"), y: number(off, "y"), width: number(ext, "cx"), height: number(ext, "cy"))
        guard raw.width >= 0, raw.height >= 0, raw.width + raw.height > 0 else { return nil }
        let value = raw.applying(matrix)
        guard [value.minX, value.minY, value.width, value.height].allSatisfy({ $0.isFinite && abs($0) < 100000 }) else { return nil }; return value
    }
    func children(_ tree: ReaderXML, matrix: CGAffineTransform, rels: [String: String], context: CGContext, skipPlaceholders: Bool, depth: Int, groupFill: UIColor? = nil) {
        guard depth < 32 else { warnings.insert("PPTX 组合图形嵌套过深。"); return }
        for shape in tree.children {
            if shape.name == "AlternateContent" {
                if let fallback = shape.children.first(where: { $0.name == "Fallback" }) { children(fallback, matrix: matrix, rels: rels, context: context, skipPlaceholders: skipPlaceholders, depth: depth + 1, groupFill: groupFill) }; continue
            }
            if skipPlaceholders && !shape.descendants("ph").isEmpty { continue }
            if shape.name == "grpSp" {
                guard let x = transform(shape), let dest = rect(x, matrix: matrix), let org = x.children.first(where: { $0.name == "chOff" }), let ext = x.children.first(where: { $0.name == "chExt" }), number(ext, "cx") > 0, number(ext, "cy") > 0 else { continue }
                let sx = dest.width / number(ext, "cx"), sy = dest.height / number(ext, "cy")
                let next = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: dest.minX - number(org, "x") * sx, ty: dest.minY - number(org, "y") * sy)
                let props = shape.children.first { $0.name == "grpSpPr" }
                let nextFill = props?.children.contains(where: { $0.name == "noFill" }) == true ? nil : color(props?.children.first { $0.name == "solidFill" }) ?? groupFill
                children(shape, matrix: next, rels: rels, context: context, skipPlaceholders: skipPlaceholders, depth: depth + 1, groupFill: nextFill); continue
            }
            if shape.name == "graphicFrame", let pic = shape.descendants("pic").first { draw(pic, matrix: matrix, rels: rels, context: context, groupFill: groupFill); continue }
            if ["sp", "pic", "cxnSp"].contains(shape.name) { draw(shape, matrix: matrix, rels: rels, context: context, groupFill: groupFill) }
            else if shape.name == "graphicFrame" { warnings.insert("图表、表格和 SmartArt 暂未完整还原，原文件已保留。") }
        }
    }
    func draw(_ shape: ReaderXML, matrix: CGAffineTransform, rels: [String: String], context: CGContext, groupFill: UIColor? = nil) {
        let inherited = placeholder(shape, in: layout) ?? placeholder(shape, in: master)
        let x = transform(shape) ?? inherited.flatMap(transform)
        guard let box = rect(x, matrix: matrix) else { return }
        context.saveGState(); defer { context.restoreGState() }
        let angle = number(x, "rot") / 60000 * .pi / 180
        if angle != 0 { context.translateBy(x: box.midX, y: box.midY); context.rotate(by: angle); context.translateBy(x: -box.midX, y: -box.midY) }
        if x?.attributes["flipH"] == "1" || x?.attributes["flipV"] == "1" { context.translateBy(x: box.midX, y: box.midY); context.scaleBy(x: x?.attributes["flipH"] == "1" ? -1 : 1, y: x?.attributes["flipV"] == "1" ? -1 : 1); context.translateBy(x: -box.midX, y: -box.midY) }
        if shape.name == "pic" {
            guard let embed = shape.descendants("blip").first?.attributes["r:embed"], let path = rels[embed], let data = try? read(path) else { return }
            if path.lowercased().hasSuffix(".wmf") { if !ReaderWMF.draw(data, into: box, context: context) { warnings.insert("有 WMF 图像包含尚不支持的内容，原文件已保留。") } }
            else if let image = UIImage(data: data) {
                let crop = shape.descendants("srcRect").first
                let l = number(crop, "l") / 100000, t = number(crop, "t") / 100000, r = number(crop, "r") / 100000, b = number(crop, "b") / 100000
                guard 1 - l - r > 0, 1 - t - b > 0 else { return }; context.clip(to: box)
                let w = box.width / (1 - l - r), h = box.height / (1 - t - b)
                image.draw(in: CGRect(x: box.minX - l * w, y: box.minY - t * h, width: w, height: h))
            } else { warnings.insert("有图片格式无法解码，原文件已保留。") }; return
        }
        let props = shape.children.first { $0.name == "spPr" }, geom = props?.children.first { $0.name == "prstGeom" }?.attributes["prst"] ?? "rect"
        let path = shapePath(geom, box: box, properties: props)
        let fill = color(props?.children.first { $0.name == "solidFill" }) ?? (props?.children.contains(where: { $0.name == "grpFill" }) == true ? groupFill : nil)
        if geom != "line", let fill { fill.setFill(); path.fill() }
        if let line = props?.children.first(where: { $0.name == "ln" }), !line.children.contains(where: { $0.name == "noFill" }) {
            let ink = color(line.children.first { $0.name == "solidFill" }) ?? .black
            ink.setStroke(); path.lineWidth = max(0.4, number(line, "w", 9525) / 12700); path.stroke()
            if geom == "line" {
                arrow(line.children.first { $0.name == "headEnd" }, tip: box.origin, from: CGPoint(x: box.maxX, y: box.maxY), width: path.lineWidth, color: ink)
                arrow(line.children.first { $0.name == "tailEnd" }, tip: CGPoint(x: box.maxX, y: box.maxY), from: box.origin, width: path.lineWidth, color: ink)
            }
        }
        guard let body = shape.children.first(where: { $0.name == "txBody" }) else { return }
        let defaults = inherited?.descendants("defRPr").first ?? master?.descendants(shape.descendants("ph").first?.attributes["type"] == "title" ? "titleStyle" : "bodyStyle").first?.descendants("defRPr").first
        let text = ReaderSlideText.attributed(body, defaults: defaults, fontScale: 1, fonts: fonts, color: color)
        guard text.length > 0 else { return }
        let pr = body.children.first { $0.name == "bodyPr" }
        let l = number(pr, "lIns", 91440) / 12700, t = number(pr, "tIns", 45720) / 12700, r = number(pr, "rIns", 91440) / 12700, b = number(pr, "bIns", 45720) / 12700
        var area = CGRect(x: box.minX + l, y: box.minY + t, width: max(1, box.width - l - r), height: max(1, box.height - t - b))
        if pr?.attributes["wrap"] == "none" { area.size.width = max(area.width, text.size().width + 1) }
        let h = text.boundingRect(with: CGSize(width: area.width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        if pr?.attributes["anchor"] == "ctr" { area.origin.y += max(0, (area.height - h) / 2) }
        if pr?.attributes["anchor"] == "b" { area.origin.y += max(0, area.height - h) }
        area.size.height = max(area.height, h + 1); text.draw(with: area, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    func arrow(_ end: ReaderXML?, tip: CGPoint, from: CGPoint, width: CGFloat, color: UIColor) {
        guard let kind = end?.attributes["type"], ["triangle", "arrow", "stealth"].contains(kind) else { return }
        let dx = tip.x - from.x, dy = tip.y - from.y, distance = hypot(dx, dy)
        guard distance > 0 else { return }
        func factor(_ name: String) -> CGFloat { end?.attributes[name] == "sm" ? 2 : end?.attributes[name] == "lg" ? 5 : 3 }
        let length = min(distance, width * factor("len")), half = width * factor("w") / 2
        let ux = dx / distance, uy = dy / distance, base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let path = UIBezierPath(); path.move(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half)); path.addLine(to: tip); path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        if kind == "arrow" { color.setStroke(); path.lineWidth = width; path.stroke() }
        else { if kind == "stealth" { path.addLine(to: CGPoint(x: tip.x - ux * length * 0.65, y: tip.y - uy * length * 0.65)) }; path.close(); color.setFill(); path.fill() }
    }
    func shapePath(_ geom: String, box: CGRect, properties: ReaderXML?) -> UIBezierPath {
        if geom == "ellipse" { return UIBezierPath(ovalIn: box) }
        if geom == "roundRect" { return UIBezierPath(roundedRect: box, cornerRadius: min(box.width, box.height) * 0.12) }
        let path = UIBezierPath()
        if geom == "line" { path.move(to: box.origin); path.addLine(to: CGPoint(x: box.maxX, y: box.maxY)); return path }
        if geom == "leftBrace" || geom == "rightBrace" {
            let sign: CGFloat = geom == "leftBrace" ? 1 : -1, left = geom == "leftBrace" ? box.minX : box.maxX
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: left + sign * box.width * x, y: box.minY + box.height * y) }
            path.move(to: p(1, 0)); path.addCurve(to: p(0.5, 0.25), controlPoint1: p(0.5, 0), controlPoint2: p(0.5, 0.05)); path.addCurve(to: p(0, 0.5), controlPoint1: p(0.5, 0.45), controlPoint2: p(0.5, 0.5)); path.addCurve(to: p(0.5, 0.75), controlPoint1: p(0.5, 0.5), controlPoint2: p(0.5, 0.55)); path.addCurve(to: p(1, 1), controlPoint1: p(0.5, 0.95), controlPoint2: p(0.5, 1)); return path
        }
        if let custom = properties?.children.first(where: { $0.name == "custGeom" })?.descendants("path").first {
            let w = max(1, number(custom, "w", box.width)), h = max(1, number(custom, "h", box.height))
            for command in custom.children {
                guard let point = command.children.first(where: { $0.name == "pt" }) else { if command.name == "close" { path.close() }; continue }
                let p = CGPoint(x: box.minX + number(point, "x") / w * box.width, y: box.minY + number(point, "y") / h * box.height)
                if command.name == "moveTo" { path.move(to: p) } else if command.name == "lnTo" { path.addLine(to: p) }
            }; return path
        }
        return UIBezierPath(rect: box)
    }
}
