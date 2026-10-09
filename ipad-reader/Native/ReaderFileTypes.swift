import UniformTypeIdentifiers
import Foundation

extension UTType {
    static let yejianNotebook = UTType(exportedAs: "com.lunar0cean.yejian.notebook", conformingTo: .json)
    static let readerMarkdown = UTType(filenameExtension: "md") ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

enum ReaderFileTypes {
    private struct Header: Decodable { var engine: String? }
    static func isNotebook(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["svg", "yejiannotebook"].contains(ext) { return true }
        guard ext == "json" else { return false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 150 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let header = try? JSONDecoder().decode(Header.self, from: data) else { return false }
        return header.engine == "yejian-notebook-v1"
    }
}
