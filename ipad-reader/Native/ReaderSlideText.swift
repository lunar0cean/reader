import UIKit

/// Symbol-font bytes and Unicode private-use characters are different encodings.
/// DrawingML only converts F0xx characters; ordinary Latin text in the same run
/// remains Latin. WMF SYMBOL_CHARSET converts every byte using Adobe's table.
enum ReaderSlideSymbols {
    static let table: [UInt32: Unicode.Scalar] = {
        guard let url = Bundle.main.url(forResource: "Adobe-Symbol-Mapping", withExtension: "txt"), let data = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [UInt32: Unicode.Scalar] = [:]
        for line in data.components(separatedBy: .newlines) where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, let unicode = UInt32(fields[0], radix: 16), let byte = UInt32(fields[1], radix: 16), let scalar = Unicode.Scalar(unicode) else { continue }
            if result[byte] == nil || unicode < 0xE000 { result[byte] = scalar }
        }
        let parts: [UInt32: UInt32] = [0xE6: 0x239B, 0xE7: 0x239C, 0xE8: 0x239D, 0xE9: 0x23A1, 0xEA: 0x23A2, 0xEB: 0x23A3, 0xEC: 0x23A7, 0xED: 0x23A8, 0xEE: 0x23A9, 0xEF: 0x23AA, 0xF6: 0x239E, 0xF7: 0x239F, 0xF8: 0x23A0, 0xF9: 0x23A4, 0xFA: 0x23A5, 0xFB: 0x23A6, 0xFC: 0x23AB, 0xFD: 0x23AC, 0xFE: 0x23AD]
        for (byte, value) in parts { result[byte] = Unicode.Scalar(value) }
        return result
    }()
    static func text(_ text: String, typeface: String?) -> String {
        guard typeface?.lowercased() == "symbol" else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xF000...0xF0FF).contains(scalar.value) ? table[scalar.value - 0xF000] ?? scalar : scalar
        }))
    }
    static func bytes(_ bytes: [UInt8]) -> String { String(String.UnicodeScalarView(bytes.map { table[UInt32($0)] ?? Unicode.Scalar(UInt32($0))! })) }
    // MT Extra uses a separate encoding from Symbol. Mapping references:
    // https://www-archive.mozilla.org/projects/mathml/fonts/encoding/mtextra
    static func mathExtra(_ bytes: [UInt8]) -> String {
        let table: [UInt8: UInt32] = [0x20:0x0020, 0x23:0x0300, 0x24:0x0302, 0x25:0x0303, 0x26:0x0307, 0x3C:0x25C3, 0x3E:0x25B9, 0x43:0x2210, 0x44:0x019B, 0x49:0x2229, 0x4B:0x2026, 0x4C:0x22EF, 0x4D:0x22EE, 0x4E:0x22F0, 0x4F:0x22F1, 0x51:0x2235, 0x55:0x222A, 0x60:0x2035, 0x61:0x21A6, 0x62:0x2195, 0x63:0x21D5, 0x66:0x227B, 0x68:0x210F, 0x6C:0x2113, 0x6D:0x2213, 0x6F:0x2218, 0x70:0x227A, 0x72:0x20D7, 0x73:0x20D6, 0x74:0x20E1, 0x75:0x23AF, 0x76:0x20D1, 0x77:0x20D0, 0x7B:0xFE36, 0x7D:0xFE38]
        return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar(table[$0] ?? 0xFFFD)! }))
    }
}

enum ReaderSlideText {
    static func font(_ family: String?, size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let lower = (family ?? "Arial").lowercased()
        let name: String
        if lower.contains("symbol") || lower.contains("math") { name = "STIXTwoMath-Regular" }
        else if lower.contains("times") { name = "TimesNewRomanPS" + (bold && italic ? "-BoldItalicMT" : bold ? "-BoldMT" : italic ? "-ItalicMT" : "MT") }
        else if lower.contains("宋") || lower.contains("ming") { return ReaderFont.serif(size: size) }
        else if lower.contains("courier") { name = bold ? "CourierNewPS-BoldMT" : "CourierNewPSMT" }
        else { name = "Arial" + (bold && italic ? "-BoldItalicMT" : bold ? "-BoldMT" : italic ? "-ItalicMT" : "MT") }
        return UIFont(name: family ?? "", size: size) ?? UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    static func attributed(_ body: ReaderXML, defaults: ReaderXML?, fontScale: CGFloat, fonts: [String: String], color: (ReaderXML?) -> UIColor?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for paragraph in body.children where paragraph.name == "p" {
            let p = paragraph.children.first { $0.name == "pPr" }
            let level = p?.attributes["lvl"] ?? "0"
            let listDefault = body.children.first { $0.name == "lstStyle" }?.children.first { $0.name == "lvl\((Int(level) ?? 0) + 1)pPr" }
            let def = p?.children.first { $0.name == "defRPr" } ?? listDefault?.children.first { $0.name == "defRPr" } ?? defaults
            let begin = result.length
            for run in paragraph.children {
                if run.name == "br" { result.append(NSAttributedString(string: "\n")); continue }
                guard ["r", "fld"].contains(run.name) else { continue }
                let r = run.children.first { $0.name == "rPr" }
                func attr(_ key: String) -> String? { r?.attributes[key] ?? def?.attributes[key] }
                let family = r?.children.first { $0.name == "latin" }?.attributes["typeface"] ?? def?.children.first { $0.name == "latin" }?.attributes["typeface"] ?? "+mn-lt"
                let size = CGFloat(max(6, min(160, (Double(attr("sz") ?? "") ?? 1800) / 100))) * fontScale
                let symbol = r?.children.first { $0.name == "sym" }?.attributes["typeface"] ?? family
                let raw = run.children.filter { $0.name == "t" }.map(\.ownText).joined()
                let value = ReaderSlideSymbols.text(raw, typeface: symbol)
                var attributes: [NSAttributedString.Key: Any] = [.font: font(fonts[family] ?? family, size: size, bold: attr("b") == "1", italic: attr("i") == "1"), .foregroundColor: color(r?.children.first { $0.name == "solidFill" }) ?? color(def?.children.first { $0.name == "solidFill" }) ?? UIColor.black]
                if let offset = Double(attr("baseline") ?? "") { attributes[.baselineOffset] = size * offset / 100000 }
                if let spacing = Double(attr("spc") ?? "") { attributes[.kern] = spacing / 100 * Double(fontScale) }
                if attr("u") != nil, attr("u") != "none" { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: value, attributes: attributes))
            }
            let style = NSMutableParagraphStyle()
            switch p?.attributes["algn"] ?? listDefault?.attributes["algn"] { case "ctr": style.alignment = .center; case "r": style.alignment = .right; case "just": style.alignment = .justified; default: style.alignment = .left }
            if let pct = p?.descendants("lnSpc").first?.descendants("spcPct").first?.attributes["val"], let value = Double(pct) { style.lineHeightMultiple = value / 100000 }
            if let before = p?.descendants("spcBef").first?.descendants("spcPts").first?.attributes["val"] { style.paragraphSpacingBefore = CGFloat(Double(before) ?? 0) / 100 * fontScale }
            if let after = p?.descendants("spcAft").first?.descendants("spcPts").first?.attributes["val"] { style.paragraphSpacing = CGFloat(Double(after) ?? 0) / 100 * fontScale }
            result.append(NSAttributedString(string: "\n"))
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: begin, length: result.length - begin))
        }
        if result.length > 0 { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }
}
