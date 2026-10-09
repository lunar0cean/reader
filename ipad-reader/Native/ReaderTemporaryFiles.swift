import Foundation

enum ReaderTemporaryFiles {
    static func clearExpired() {
        let folder = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("阅读器-") || file.lastPathComponent.hasPrefix("页间-") {
                guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), info.isRegularFile == true,
                      let date = info.contentModificationDate, date < Date().addingTimeInterval(-86400) else { continue }
                // Only disposable app exports in tmp; library and model folders
                // are outside this directory and never participate in cleanup.
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
