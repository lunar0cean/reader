import PDFKit
import UIKit

/// Locate image XObjects, including images nested in reusable PDF forms.
/// The PDF renderer supplies the pixels, preserving masks and colour spaces.
enum ReaderPDFImages {
    private final class Boxes: NSObject { let values: [CGRect]; init(_ values: [CGRect]) { self.values = values } }
    private static let cache = NSCache<NSString, Boxes>()
    static func releaseCache() { cache.removeAllObjects() }
    static func rectangles(book: ReaderBook, index: Int) -> [CGRect] {
        let key = "\(book.id):\(index)" as NSString
        if let hit = cache.object(forKey: key) { return hit.values }
        guard let ref = ReaderPDF.document(book)?.page(at: index)?.pageRef else { return [] }
        let content = CGPDFContentStreamCreateWithPage(ref)
        defer { CGPDFContentStreamRelease(content) }
        let state = State()
        var dictionary: CGPDFDictionaryRef? = ref.dictionary
        for _ in 0..<20 {
            guard let current = dictionary else { break }
            if CGPDFDictionaryGetDictionary(current, "Resources", &state.resources) { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent) else { break }
            dictionary = parent
        }
        scan(content, state)
        cache.countLimit = 200; cache.setObject(Boxes(state.boxes), forKey: key)
        return state.boxes
    }
    private final class State {
        var matrix = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var boxes: [CGRect] = []
        var depth = 0
        var resources: CGPDFDictionaryRef?
    }
    private static func scan(_ stream: CGPDFContentStreamRef, _ state: State) {
        guard state.depth < 12, state.boxes.count < 2000, let table = CGPDFOperatorTableCreate() else { return }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "q") { _, raw in
            guard let raw else { return }; let state = Unmanaged<State>.fromOpaque(raw).takeUnretainedValue(); state.stack.append(state.matrix)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, raw in
            guard let raw else { return }; let state = Unmanaged<State>.fromOpaque(raw).takeUnretainedValue(); state.matrix = state.stack.popLast() ?? .identity
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, raw in
            guard let raw else { return }; let state = Unmanaged<State>.fromOpaque(raw).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &values[i]) else { return } }
            state.matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]).concatenating(state.matrix)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, raw in
            guard let raw else { return }; let state = Unmanaged<State>.fromOpaque(raw).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name) else { return }
            var value: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &value), let value else { return }
            guard let dict = CGPDFStreamGetDictionary(value) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            if String(cString: subtype) == "Image" {
                var mask: CGPDFBoolean = 0
                if CGPDFDictionaryGetBoolean(dict, "ImageMask", &mask), mask != 0 { return }
                let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.matrix).standardized
                if box.width > 2, box.height > 2 { state.boxes.append(box) }
            } else if String(cString: subtype) == "Form", state.depth < 12 {
                var resources = state.resources
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                guard let resources else { return }
                let parent = CGPDFScannerGetContentStream(scanner)
                let child = CGPDFContentStreamCreateWithStream(value, resources, parent)
                let nested = State(); nested.matrix = state.matrix; nested.depth = state.depth + 1; nested.resources = resources
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var n = [CGPDFReal](repeating: 0, count: 6)
                    if (0..<6).allSatisfy({ CGPDFArrayGetNumber(array, $0, &n[$0]) }) {
                        nested.matrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.matrix)
                    }
                }
                ReaderPDFImages.scan(child, nested); state.boxes.append(contentsOf: nested.boxes.prefix(2000 - min(2000, state.boxes.count)))
                CGPDFContentStreamRelease(child)
            }
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        _ = CGPDFScannerScan(scanner); CGPDFScannerRelease(scanner)
    }
}
