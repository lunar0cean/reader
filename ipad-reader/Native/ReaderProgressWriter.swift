import Foundation
import UIKit

/// Coalesce page-position writes and encode large source files off the UI thread.
/// Explicit saves use the same serial queue, so an older pending write cannot
/// overwrite a newer import, stroke, note or background save.
typealias ReaderProgressWriter = DocumentWriter<NativeBackup>

final class DocumentWriter<Snapshot: Encodable> {
    private let queue = DispatchQueue(label: "yejian.reader.persistence", qos: .utility)
    private let lock = NSLock()
    private var revision = 0
    private var pending: DispatchWorkItem?
    private let url: URL
    private let write: (Snapshot, URL) throws -> Void
    init(url: URL, write: @escaping (Snapshot, URL) throws -> Void = { try JSONEncoder().encode($0).write(to: $1, options: .atomic) }) { self.url = url; self.write = write }
    private func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        revision += 1; return revision
    }
    private func isCurrent(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return revision == value
    }
    func save(_ snapshot: Snapshot) throws {
        pending?.cancel(); pending = nil; _ = advance()
        try queue.sync { try write(snapshot, url) }
    }
    func schedule(_ snapshot: Snapshot, onError: @escaping @MainActor (String) -> Void) {
        pending?.cancel(); let value = advance()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(value) else { return }
            do {
                guard self.isCurrent(value) else { return }
                try self.write(snapshot, self.url)
            } catch {
                guard self.isCurrent(value) else { return }
                let message = error.localizedDescription
                DispatchQueue.main.async { onError(message) }
            }
        }
        pending = work; queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    @MainActor func saveInBackground(_ snapshot: Snapshot, onError: @escaping @MainActor (String) -> Void) {
        pending?.cancel(); pending = nil; let value = advance()
        let lifetime = PersistenceBackgroundTask(); lifetime.start()
        queue.async { [self] in
            defer { DispatchQueue.main.async { lifetime.end() } }
            guard isCurrent(value) else { return }
            do { try write(snapshot, url) }
            catch { let message = error.localizedDescription; DispatchQueue.main.async { onError(message) } }
        }
    }
}

@MainActor private final class PersistenceBackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid
    func start() { id = UIApplication.shared.beginBackgroundTask(withName: "保存阅读和笔记") { [weak self] in self?.end() } }
    func end() { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
}
