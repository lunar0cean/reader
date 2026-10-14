import Foundation

/// A cancellable import owns its progress; stale callbacks cannot update a new job.
final class ReaderImportControl {
    private let lock = NSLock()
    private var cancelled = false
    private let started = Date()
    private let report: (String) -> Void
    init(report: @escaping (String) -> Void = { _ in }) { self.report = report }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
        if Date().timeIntervalSince(started) > 180 { throw ReaderFileError.invalid("文件解析超过三分钟，已停止。复杂 PPT 可先导出 PDF；原文件未被更改。") }
    }
    func progress(_ status: String) { report(status) }
}
