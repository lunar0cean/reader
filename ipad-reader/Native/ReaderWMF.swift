import UIKit

/// Bounded interpreter for the vector records used by legacy Office equation
/// pictures. No embedded OLE program, escape command or external file is run.
enum ReaderWMF {
    private struct Font { var height: CGFloat = 12; var family = "Times New Roman"; var bold = false; var italic = false; var charset = 0 }
    private struct Pen { var color = UIColor.black; var width: CGFloat = 1; var hidden = false }
    private struct Brush { var color = UIColor.white; var hidden = true }
    private enum Object { case font(Font), pen(Pen), brush(Brush) }
    private struct State {
        var origin = CGPoint.zero, extent = CGSize(width: 1, height: 1), position = CGPoint.zero
        var font = Font(), pen = Pen(), brush = Brush(), color = UIColor.black, background = UIColor.white
        var alignment = 0, backgroundMode = 1
    }
    static func draw(_ data: Data, into rect: CGRect, context: CGContext) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes.count <= 2_000_000, rect.width > 0, rect.height > 0 else { return false }
        func u16(_ i: Int) -> Int { guard i >= 0, i + 1 < bytes.count else { return 0 }; return Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func s16(_ i: Int) -> Int { let value = u16(i); return value >= 0x8000 ? value - 0x10000 : value }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func color(_ i: Int) -> UIColor { UIColor(red: CGFloat(bytes[i]) / 255, green: CGFloat(bytes[i + 1]) / 255, blue: CGFloat(bytes[i + 2]) / 255, alpha: 1) }
        var state = State(), objects: [Object?] = [], saved: [State] = []
        var offset = 0, records = 0, supported = true, painted = false
        if u32(0) == 0x9AC6CDD7 {
            guard bytes.count >= 40 else { return false }
            state.origin = CGPoint(x: CGFloat(s16(6)), y: CGFloat(s16(8))); state.extent = CGSize(width: CGFloat(s16(10) - s16(6)), height: CGFloat(s16(12) - s16(8))); offset = 22
            guard state.extent.width != 0, state.extent.height != 0 else { return false }
        }
        guard [1, 2].contains(u16(offset)), u16(offset + 2) == 9, u16(offset + 10) <= 1024 else { return false }; offset += 18
        context.saveGState(); context.clip(to: rect); UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext(); context.restoreGState() }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - state.origin.x) / state.extent.width * rect.width, y: rect.minY + (y - state.origin.y) / state.extent.height * rect.height) }
        func insert(_ object: Object) { if let index = objects.firstIndex(where: { $0 == nil }) { objects[index] = object } else if objects.count < 1024 { objects.append(object) } }
        while offset + 6 <= bytes.count {
            records += 1; guard records <= 50000 else { return false }
            let words = u32(offset), op = u16(offset + 4)
            guard words >= 3, words <= (bytes.count - offset) / 2 else { return false }
            let p = offset + 6, end = offset + words * 2, length = end - p
            defer { offset = end }
            if op == 0 { break }
            switch op {
            case 0x020B where length >= 4: state.origin = CGPoint(x: CGFloat(s16(p + 2)), y: CGFloat(s16(p)))
            case 0x020C where length >= 4: state.extent = CGSize(width: CGFloat(s16(p + 2)), height: CGFloat(s16(p))); if state.extent.width == 0 || state.extent.height == 0 { return false }
            case 0x0214 where length >= 4: state.position = CGPoint(x: CGFloat(s16(p + 2)), y: CGFloat(s16(p)))
            case 0x0209 where length >= 4: state.color = color(p)
            case 0x0201 where length >= 4: state.background = color(p)
            case 0x0102 where length >= 2: state.backgroundMode = u16(p)
            case 0x012E where length >= 2: state.alignment = u16(p)
            case 0x02FB where length >= 18:
                let nameEnd = (p + 18..<end).first(where: { bytes[$0] == 0 }) ?? end
                let family = String(bytes: bytes[p + 18..<nameEnd], encoding: .windowsCP1252) ?? "Times New Roman"
                insert(.font(Font(height: CGFloat(abs(s16(p))), family: family, bold: s16(p + 8) >= 600, italic: bytes[p + 10] != 0, charset: Int(bytes[p + 13]))))
            case 0x02FA where length >= 10: insert(.pen(Pen(color: color(p + 6), width: CGFloat(max(1, abs(s16(p + 2)))), hidden: u16(p) & 0xF == 5)))
            case 0x02FC where length >= 8: insert(.brush(Brush(color: color(p + 2), hidden: u16(p) == 1)))
            case 0x012D where length >= 2:
                let index = u16(p)
                if objects.indices.contains(index), let object = objects[index] { switch object { case .font(let font): state.font = font; case .pen(let pen): state.pen = pen; case .brush(let brush): state.brush = brush } }
            case 0x01F0 where length >= 2: let index = u16(p); if objects.indices.contains(index) { objects[index] = nil }
            case 0x001E: saved.append(state)
            case 0x0127: if let previous = saved.popLast() { state = previous }
            case 0x0213 where length >= 4:
                let target = CGPoint(x: CGFloat(s16(p + 2)), y: CGFloat(s16(p)))
                if !state.pen.hidden {
                    context.setStrokeColor(state.pen.color.cgColor); context.setLineWidth(max(0.3, state.pen.width / abs(state.extent.width) * rect.width))
                    context.move(to: point(state.position.x, state.position.y)); context.addLine(to: point(target.x, target.y)); context.strokePath(); painted = true
                }; state.position = target
            case 0x0324, 0x0325:
                guard length >= 2, u16(p) <= (length - 2) / 4 else { return false }
                let count = u16(p); context.beginPath()
                for i in 0..<count { let location = point(CGFloat(s16(p + 2 + 4 * i)), CGFloat(s16(p + 4 + 4 * i))); if i == 0 { context.move(to: location) } else { context.addLine(to: location) } }
                if op == 0x0324 { context.closePath() }
                context.setStrokeColor(state.pen.color.cgColor); context.setFillColor(state.brush.color.cgColor)
                context.setLineWidth(max(0.3, state.pen.width / abs(state.extent.width) * rect.width))
                context.drawPath(using: op == 0x0324 && !state.brush.hidden ? (state.pen.hidden ? .fill : .fillStroke) : .stroke); painted = true
            case 0x041B, 0x0418:
                guard length >= 8 else { return false }
                let a = point(CGFloat(s16(p + 6)), CGFloat(s16(p + 4))), b = point(CGFloat(s16(p + 2)), CGFloat(s16(p)))
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                let path = op == 0x0418 ? UIBezierPath(ovalIn: box) : UIBezierPath(rect: box)
                if !state.brush.hidden { state.brush.color.setFill(); path.fill() }
                if !state.pen.hidden { state.pen.color.setStroke(); path.lineWidth = max(0.3, state.pen.width / abs(state.extent.width) * rect.width); path.stroke() }; painted = true
            case 0x0A32, 0x0521:
                guard length >= (op == 0x0A32 ? 8 : 6) else { return false }
                let count = u16(p + (op == 0x0A32 ? 4 : 0)), options = op == 0x0A32 ? u16(p + 6) : 0
                let start = p + (op == 0x0A32 ? 8 + (options & 6 != 0 ? 8 : 0) : 2)
                guard count > 0, count <= 10000, start + count <= end else { return false }
                let paddedEnd = start + count + count % 2
                if op == 0x0521 && paddedEnd + 4 > end { return false }
                let location = state.alignment & 1 != 0 ? state.position : CGPoint(x: CGFloat(s16(op == 0x0A32 ? p + 2 : paddedEnd + 2)), y: CGFloat(s16(op == 0x0A32 ? p : paddedEnd)))
                let raw = Array(bytes[start..<start + count])
                let extra = state.font.family.lowercased().contains("mt extra")
                let symbolic = state.font.charset == 2 || state.font.family.lowercased() == "symbol"
                let text = extra ? ReaderSlideSymbols.mathExtra(raw) : symbolic ? ReaderSlideSymbols.bytes(raw) : String(bytes: raw, encoding: .windowsCP1252) ?? ""
                let font = ReaderSlideText.font(symbolic || extra ? "STIXTwoMath-Regular" : state.font.family, size: max(1, state.font.height / abs(state.extent.height) * rect.height), bold: state.font.bold, italic: state.font.italic)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: state.color]
                var pos = point(location.x, location.y)
                if state.alignment & 0x18 == 0x18 { pos.y -= font.ascender } else if state.alignment & 8 != 0 { pos.y -= font.lineHeight }
                let useDx = paddedEnd + count * 2 <= end && op == 0x0A32
                let advance = useDx ? (0..<count).reduce(CGFloat(0)) { $0 + CGFloat(s16(paddedEnd + 2 * $1)) / state.extent.width * rect.width } : (text as NSString).size(withAttributes: attributes).width
                if state.alignment & 6 == 6 { pos.x -= advance / 2 } else if state.alignment & 2 != 0 { pos.x -= advance }
                if state.backgroundMode == 2 { context.setFillColor(state.background.cgColor); context.fill(CGRect(origin: pos, size: CGSize(width: advance, height: font.lineHeight))) }
                if useDx && text.unicodeScalars.count == count {
                    for (i, scalar) in text.unicodeScalars.enumerated() { (String(scalar) as NSString).draw(at: pos, withAttributes: attributes); pos.x += CGFloat(s16(paddedEnd + 2 * i)) / state.extent.width * rect.width }
                } else { (text as NSString).draw(at: pos, withAttributes: attributes) }; painted = true
                if state.alignment & 1 != 0 { state.position.x += advance / rect.width * state.extent.width }
            case 0x0103, 0x0104, 0x0106, 0x0107, 0x0108, 0x0231, 0x0626:
                // Mapping hints and inert comments. The window coordinates are
                // mapped directly; embedded PostScript escapes are never run.
                break
            default: supported = false
            }
        }
        return supported && painted
    }
}
