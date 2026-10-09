import Foundation
import UIKit

struct VoicePreset: Identifiable {
    let url: URL
    let name: String
    let language: String
    var id: URL { url }
}

/// 界面状态。合成在后台队列上跑，界面状态只在主线程上改。
final class AppModel: ObservableObject {
    @Published var presets: [VoicePreset] = []
    @Published var selected: URL?
    @Published var language = "ja"
    @Published var text = ""
    @Published var busy = false
    @Published var playing = false
    @Published var paused = false
    @Published var playbackMark: SpeechMark?
    @Published var rate = UserDefaults.standard.object(forKey: "reader-speech-rate") as? Double ?? 1 { didSet { UserDefaults.standard.set(rate, forKey: "reader-speech-rate"); player?.rate = Float(rate) } }
    @Published var chineseVoice: URL? { didSet { remember(chineseVoice, language: "zh") } }
    @Published var japaneseVoice: URL? { didSet { remember(japaneseVoice, language: "ja") } }
    @Published var languageMode = UserDefaults.standard.string(forKey: "reader-speech-language") ?? "auto" { didSet { UserDefaults.standard.set(languageMode, forKey: "reader-speech-language") } }
    @Published var highlightEnabled = UserDefaults.standard.object(forKey: "reader-speech-highlight") as? Bool ?? true { didSet { UserDefaults.standard.set(highlightEnabled, forKey: "reader-speech-highlight") } }
    @Published var status = ""
    @Published var missingFiles: [String] = []
    /// 文档目录里有没有中文语调模型。它是可选的，没有时中文也能读，只是语气偏平
    @Published var bertInstalled = false
    /// 音频增强（均衡、压缩、统一响度），与电脑上网页界面的同名选项相同。默认打开，选择会记住
    @Published var enhance: Bool = UserDefaults.standard.object(forKey: "enhance") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enhance, forKey: "enhance") }
    }
    /// 在 iPad 上加角色要用的模型还缺哪些
    @Published var voiceModelsMissing: [String] = []
    /// 拷进本 App 的录音，加角色时直接列出来选
    @Published var recordings: [URL] = []

    private static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "flac", "aac", "aif", "aiff", "caf"]

    private var modelDirectory: URL?
    private var voiceModels: [String: URL] = [:]
    private var bertURL: URL?
    private var engine: SynthEngine?
    private var bertEngine: BertEngine?
    private var frontend: TextFrontend?
    private let player = StreamPlayer(sampleRate: SynthEngine.sampleRate)
    private let worker = DispatchQueue(label: "gptsovits.synth", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancelRequested = false
    private var pauseRequested = false
    private var sourceID = ""
    private var resumeOffsets = UserDefaults.standard.dictionary(forKey: "reader-speech-offsets") as? [String: Int] ?? [:]
    var reading: Bool { busy || playing || paused }

    init() {
        player?.rate = Float(rate)
        player?.onPlaybackChanged = { [weak self] value in
            self?.playing = value
            if !value, self?.busy == false, self?.paused == false { self?.clearAudioCache(); self?.playbackMark = nil }
        }
        player?.onSegmentStarted = { [weak self] range in
            guard let self else { return }
            self.playbackMark = SpeechMark(sourceID: self.sourceID, range: range)
            self.resumeOffsets[self.sourceID] = range.location
            self.persistOffsets()
        }
        player?.onSegmentFinished = { [weak self] range in
            guard let self else { return }
            self.resumeOffsets[self.sourceID] = NSMaxRange(range); self.persistOffsets()
        }
        clearAudioCache()
    }

    /// Generated speech is disposable. Models, voice packs and reference recordings are never removed.
    func clearAudioCache() {
        let folder = Self.documents.appendingPathComponent("outputs", isDirectory: true)
        worker.async {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension.lowercased() == "wav" {
                try? fm.removeItem(at: url)
            }
        }
    }

    // A16 有 2 个性能核，推理线程数与之对应
    private static let threads = 2

    var modelsReady: Bool { modelDirectory != nil }
    var ready: Bool { modelsReady && !presets.isEmpty }
    var canGenerate: Bool {
        !busy && ready && selected != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 在本 App 的文件夹里找模型和角色包，放在哪一层子文件夹都可以。
    func refresh() {
        guard !busy else { return }
        let fm = FileManager.default
        let docs = AppModel.documents
        AppModel.writeGuide(in: docs)

        var foundDirectory: URL?
        var foundBert: URL?
        var found: [VoicePreset] = []
        var foundVoiceModels: [String: URL] = [:]
        var encoders: [URL] = []
        var foundRecordings: [URL] = []
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("VoiceModels", isDirectory: true)
        let roots = [bundled, docs].compactMap { $0 }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "reader-hidden-bundled-voices") ?? [])
        for root in roots {
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if ["outputs", "reader-library", "notebook-library", "Inbox"].contains(name) {
                    walker.skipDescendants()  // 合成出来的音频不算录音
                    continue
                }
                if name == "vits_fp32.onnx" {
                    let candidate = url.deletingLastPathComponent()
                    if SynthEngine.modelFiles.allSatisfy({ fm.fileExists(atPath: candidate.appendingPathComponent($0).path) }) {
                        foundDirectory = candidate
                    }
                }
                if name == BertEngine.fileName {
                    foundBert = url
                }
                if name == "hubert.onnx" || name == "sv.onnx" {
                    foundVoiceModels[name] = url
                }
                if name == "prompt_encoder_fp32.onnx" {
                    encoders.append(url)
                }
                if AppModel.audioExtensions.contains(url.pathExtension.lowercased()) {
                    foundRecordings.append(url)
                }
                guard url.pathExtension == "gsvpack", !(root == bundled && hidden.contains(url.lastPathComponent)),
                      let pack = try? TensorPack(url: url), (try? pack.validateVoice()) != nil else {
                    continue
                }
                found.append(VoicePreset(url: url,
                                         name: pack.meta["name"] ?? url.deletingPathExtension().lastPathComponent,
                                         language: pack.meta["lang"] ?? "ja"))
            }
        }
        }

        let directory = foundDirectory ?? docs.appendingPathComponent("models", isDirectory: true)
        let missingModels = SynthEngine.modelFiles.filter {
            !fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        missingFiles = missingModels

        // 音色编码器的 .onnx 只记着权重文件的名字，两个文件必须在同一个文件夹
        if let encoder = encoders.last(where: {
            fm.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent("prompt_encoder_fp32.bin").path)
        }) {
            foundVoiceModels["prompt_encoder_fp32.onnx"] = encoder
        }
        voiceModels = foundVoiceModels
        voiceModelsMissing = ["hubert.onnx", "sv.onnx", "prompt_encoder_fp32.onnx"].filter { foundVoiceModels[$0] == nil }
            .map { $0 == "prompt_encoder_fp32.onnx" ? "prompt_encoder_fp32.onnx 和 prompt_encoder_fp32.bin（放在一起）" : $0 }
        recordings = foundRecordings.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let newDirectory = missingModels.isEmpty ? directory : nil
        if modelDirectory != newDirectory {
            engine = nil
            modelDirectory = newDirectory
        }
        if bertURL != foundBert {
            bertEngine = nil
            bertURL = foundBert
        }
        bertInstalled = foundBert != nil

        // 文件名前面的序号决定显示顺序
        presets = Dictionary(found.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { _, newer in newer }).values.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        if !presets.contains(where: { $0.url == chineseVoice }) { chineseVoice = rememberedVoice("zh") ?? presets.first(where: { $0.language == "zh" })?.url ?? presets.first?.url }
        if !presets.contains(where: { $0.url == japaneseVoice }) { japaneseVoice = rememberedVoice("ja") ?? presets.first(where: { $0.language == "ja" })?.url ?? presets.first?.url }
        if selected == nil, let remembered = UserDefaults.standard.string(forKey: "reader-voice-file") {
            selected = presets.first(where: { $0.url.lastPathComponent == remembered })?.url
        }
        if !presets.contains(where: { $0.url == selected }) {
            selected = nil
            if let first = presets.first {
                select(first)
            }
        }
        // Reading and handwriting do not load 1+ GB of speech models.
        // Models are loaded on the serial worker only when synthesis starts.
    }
    private func rememberedVoice(_ language: String) -> URL? {
        let name = UserDefaults.standard.string(forKey: "reader-voice-" + language)
        return presets.first(where: { $0.url.lastPathComponent == name })?.url
    }
    private func remember(_ url: URL?, language: String) {
        if let url { UserDefaults.standard.set(url.lastPathComponent, forKey: "reader-voice-" + language) }
    }
    private func persistOffsets() {
        if resumeOffsets.count > 100 { resumeOffsets = [sourceID: resumeOffsets[sourceID] ?? 0] }
        UserDefaults.standard.set(resumeOffsets, forKey: "reader-speech-offsets")
    }
    func speak(_ text: String, sourceID: String) {
        if self.sourceID == sourceID && paused { resume(); return }
        guard !busy else { return }
        self.sourceID = sourceID; self.text = text; language = languageMode == "auto" ? SpeechText.language(text) : languageMode
        selected = language == "zh" ? chineseVoice : japaneseVoice
        if (resumeOffsets[sourceID] ?? 0) >= (text as NSString).length { resumeOffsets[sourceID] = 0 }
        generate()
    }
    func resetPosition(for id: String) { resumeOffsets[id] = 0; persistOffsets() }
    func pause() {
        guard reading, !paused else { return }
        cancelLock.lock(); pauseRequested = true; cancelLock.unlock()
        paused = true; player?.pause(); status = "已暂停，点击继续"
    }
    func resume() {
        cancelLock.lock(); pauseRequested = false; cancelLock.unlock()
        paused = false; player?.resume(); status = "继续朗读"
    }
    private var isPaused: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return pauseRequested }

    func select(_ preset: VoicePreset) {
        selected = preset.url
        UserDefaults.standard.set(preset.url.lastPathComponent, forKey: "reader-voice-file")
        if preset.language == "ja" || preset.language == "zh" {
            language = preset.language
        }
    }

    /// 只在后台队列上调用。队列是串行的，所以不会同时载入两份模型。
    private func loadIfNeeded(directory: URL) throws -> (TextFrontend, SynthEngine) {
        let frontend = try loadFrontendIfNeeded()
        let engine = try DispatchQueue.main.sync(execute: { self.engine })
            ?? SynthEngine(modelDirectory: directory, threads: AppModel.threads)
        DispatchQueue.main.sync { self.engine = engine }
        return (frontend, engine)
    }

    /// 只在后台队列上调用。
    private func loadFrontendIfNeeded() throws -> TextFrontend {
        let frontend = try DispatchQueue.main.sync(execute: { self.frontend }) ?? TextFrontend()
        DispatchQueue.main.sync { self.frontend = frontend }
        return frontend
    }

    /// 只在后台队列上调用。中文语调模型载入后占 1GB 以上内存，所以只在第一次合成中文时才载入。
    private func loadBertIfNeeded(url: URL) throws -> BertEngine {
        if let cached = DispatchQueue.main.sync(execute: { self.bertEngine }) {
            return cached
        }
        DispatchQueue.main.async { self.status = "正在载入中文语调模型…" }
        let start = CFAbsoluteTimeGetCurrent()
        let loaded = try BertEngine(modelURL: url, threads: AppModel.threads)
        AppModel.log(String(format: "中文语调模型载入用时 %.1f 秒，内存占用 %.0f MB",
                            CFAbsoluteTimeGetCurrent() - start, memoryFootprintMB()))
        DispatchQueue.main.sync { self.bertEngine = loaded }
        return loaded
    }

    /// 在 iPad 上新建角色：录音 + 录音里说的话 -> 角色包，存进 voices 文件夹。
    /// `completion` 在主线程上调用，参数表示成没成功。
    func addVoice(name: String, language: String, audio: URL, transcript: String,
                  completion: @escaping (Bool) -> Void) {
        guard !busy, voiceModelsMissing.isEmpty else { return }
        player?.stop()
        engine = nil
        let models = voiceModels
        let bertURL = language == "zh" ? self.bertURL : nil
        busy = true
        status = "正在处理录音里的文字…"
        UIApplication.shared.isIdleTimerDisabled = true

        worker.async { [weak self] in
            guard let self else { return }
            let clock = CFAbsoluteTimeGetCurrent()
            var created: URL?
            var failure: String?
            do {
                let reference = try self.loadFrontendIfNeeded().reference(transcript, language: language)
                var refBert: NSMutableData?
                if let bertURL, let ids = reference.bertIds, let repeats = reference.bertRepeats {
                    do {
                        refBert = try self.loadBertIfNeeded(url: bertURL).features(ids: ids, repeats: repeats)
                    } catch {
                        AppModel.log("参考文字的语调特征没算出来：\(error.localizedDescription)")
                    }
                }
                // 中文语调模型最占内存，接下来要依次载入三个模型，先把它放掉；下次合成中文时会重新载入
                DispatchQueue.main.sync { self.bertEngine = nil }

                let tensors = try VoiceBuilder.build(audio: audio, reference: reference, refBert: refBert,
                                                     models: models, threads: AppModel.threads) { message in
                    DispatchQueue.main.async { self.status = message }
                }
                let folder = AppModel.documents.appendingPathComponent("voices", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(AppModel.voiceFileName(for: name))
                try TensorPack.write(to: url, kind: "voice", meta: ["name": name, "lang": language, "source": "ipad"],
                                     tensors: tensors)
                created = url
                AppModel.log("新建角色「\(name)」：语言 \(language)，参考音素 \(reference.ids.count) 个，"
                    + "语调特征 \(refBert == nil ? "未使用" : "已使用")，"
                    + String(format: "用时 %.1f 秒，内存占用 %.0f MB", CFAbsoluteTimeGetCurrent() - clock, memoryFootprintMB()))
            } catch {
                failure = error.localizedDescription
                AppModel.log("新建角色「\(name)」失败：\(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                self.busy = false
                if let created {
                    self.refresh()
                    if let preset = self.presets.first(where: { $0.url == created }) {
                        self.select(preset)
                    }
                    self.status = "已添加角色「\(name)」"
                } else {
                    self.status = "没有加成：\(failure ?? "未知错误")"
                }
                completion(created != nil)
            }
        }
    }

    /// 角色包的文件名：u + 时间 + 名字里的字母和数字。u 排在电脑上做的 01_、02_ 后面
    private static func voiceFileName(for name: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        var safe = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) && safe.count < 24 {
            safe.append(scalar)
        }
        return "u\(formatter.string(from: Date()))" + (safe.isEmpty ? "" : "_\(String(safe))") + ".gsvpack"
    }

    /// 录音旁边同名的 .txt（比如 ref.wav 和 ref.txt）里写的就是录音里说的话。
    func transcript(for audio: URL) -> String? {
        let url = audio.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func delete(_ preset: VoicePreset) {
        guard !busy else { return }
        do {
            if preset.url.path.hasPrefix(Bundle.main.bundleURL.path + "/") {
                var hidden = UserDefaults.standard.stringArray(forKey: "reader-hidden-bundled-voices") ?? []
                hidden.append(preset.url.lastPathComponent); UserDefaults.standard.set(hidden, forKey: "reader-hidden-bundled-voices")
            } else { try FileManager.default.removeItem(at: preset.url) }
            status = "已删除角色「\(preset.name)」"
        } catch {
            status = "删除失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func generate() {
        guard canGenerate, let directory = modelDirectory, let voiceURL = selected else { return }
        busy = true
        clearAudioCache()
        setCancelled(false)
        cancelLock.lock(); pauseRequested = false; cancelLock.unlock(); paused = false
        player?.stop()
        status = engine == nil ? "正在载入模型…" : "正在处理文字…"
        // 长文本要合成几分钟。期间不让屏幕自动锁定：锁屏后系统会把 App 挂起，合成和播放都会停下
        UIApplication.shared.isIdleTimerDisabled = true

        let text = self.text
        let startOffset = resumeOffsets[sourceID] ?? 0
        let language = self.language
        let bertURL = language == "zh" ? self.bertURL : nil
        let enhancer = enhance ? Enhancer(sampleRate: SynthEngine.sampleRate) : nil
        worker.async { [weak self] in
            guard let self else { return }
            var sampleCount = 0
            var seconds = 0.0
            var cancelled = false
            var skipped: [Int] = []
            var failure: String?
            do {
                let (frontend, engine) = try self.loadIfNeeded(directory: directory)
                let items = try SpeechText.chunks(text, from: startOffset).flatMap { chunk -> [(TextSegment, NSRange, Bool)] in
                    let prepared = try frontend.prepare(chunk.text, language: language)
                    return prepared.enumerated().map { ($0.element, chunk.range, $0.offset == prepared.count - 1) }
                }
                let segments = items.map { $0.0 }
                guard !segments.isEmpty else {
                    throw FrontendError.failed("没有可以合成的文字")
                }
                let voice = try TensorPack(url: voiceURL)
                try voice.validateVoice()

                // 语调模型载入失败不影响合成，退回全零特征
                var bert: BertEngine?
                if let bertURL {
                    do {
                        bert = try self.loadBertIfNeeded(url: bertURL)
                    } catch {
                        AppModel.log("中文语调模型载入失败：\(error.localizedDescription)")
                    }
                }
                AppModel.log("开始：\(segments.count) 句，语言 \(language)，角色包 \(voiceURL.lastPathComponent)，"
                    + "中文语调模型 \(bert == nil ? "未使用" : "已使用")，音频增强 \(enhancer == nil ? "关" : "开")")

                for (index, segment) in segments.enumerated() {
                    while !self.isCancelled && (self.isPaused || DispatchQueue.main.sync(execute: { self.player?.queuedCount ?? 0 }) >= 2) { Thread.sleep(forTimeInterval: 0.05) }
                    if self.isCancelled { cancelled = true; break }
                    DispatchQueue.main.async { self.status = "正在合成第 \(index + 1) / \(segments.count) 句" }

                    var textBert: NSMutableData?
                    if let bert, let ids = segment.bertIds, let repeats = segment.bertRepeats {
                        do {
                            textBert = try bert.features(ids: ids, repeats: repeats)
                        } catch {
                            AppModel.log("第 \(index + 1) 句的语调特征没算出来：\(error.localizedDescription)")
                        }
                    }

                    // 一句出错不拖累后面的句子：重试一次，还不行就跳过这一句
                    var samples: [Float]?
                    for attempt in 1...2 {
                        do {
                            guard let result = try engine.synthesize(voice: voice, phonemes: segment.ids,
                                                                     textBert: textBert,
                                                                     isCancelled: { self.isCancelled }) else {
                                cancelled = true
                                break
                            }
                            seconds += result.stats.seconds
                            samples = AudioPost.trimAndFade(result.samples, sampleRate: SynthEngine.sampleRate)
                            AppModel.log("第 \(index + 1) 句：音素 \(result.stats.phones)，语义 \(result.stats.tokens)，"
                                + "内部重试 \(result.stats.attempts - 1) 次，"
                                + String(format: "用时 %.1f 秒，音频 %.1f 秒", result.stats.seconds, result.stats.audioSeconds))
                            break
                        } catch {
                            AppModel.log("第 \(index + 1) 句第 \(attempt) 次失败：\(error.localizedDescription)｜\(segment.text)")
                        }
                    }
                    if cancelled {
                        break
                    }
                    guard var samples else {
                        skipped.append(index + 1)
                        continue
                    }
                    let pause = Int(segment.pause * Double(SynthEngine.sampleRate))
                    samples.append(contentsOf: [Float](repeating: 0, count: max(0, pause)))
                    // 连同后面的停顿一起处理，混响的尾音才有地方落
                    if let enhancer {
                        samples = enhancer.process(samples)
                    }
                    sampleCount += samples.count
                    do {
                        try DispatchQueue.main.sync {
                            if !self.isCancelled { try self.player?.enqueue(samples, range: items[index].1, completesRange: items[index].2) }
                        }
                    } catch {
                        AppModel.log("第 \(index + 1) 句播放失败：\(error.localizedDescription)")
                    }
                }
            } catch {
                failure = error.localizedDescription
                AppModel.log("中断：\(error.localizedDescription)")
            }

            let audioSeconds = Double(sampleCount) / Double(SynthEngine.sampleRate)
            var message: String
            if let failure {
                message = failure
            } else if cancelled {
                message = "已停止"
            } else {
                message = String(format: "完成　音频 %.1f 秒，合成用时 %.1f 秒", audioSeconds, seconds)
                if !skipped.isEmpty {
                    message += "；第 " + skipped.map { String($0) }.joined(separator: "、") + " 句没有合成出来"
                }
            }
            AppModel.log("结束：\(message)" + String(format: "　内存占用 %.0f MB", memoryFootprintMB()))

            let finalMessage = message
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                self.status = finalMessage
                self.busy = false
                if !self.playing && !self.paused { self.playbackMark = nil }
                self.clearAudioCache()
            }
        }
    }

    /// 往 outputs/log.txt 追加一行。排查「中途停下」这类问题时看它，可以用「文件」App 或电脑上的「Apple 设备」取出来。
    private static func log(_ line: String) {
        let folder = documents.appendingPathComponent("outputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("log.txt")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let data = "\(formatter.string(from: Date()))  \(line)\n".data(using: .utf8) else { return }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 512 * 1024 {
            try? FileManager.default.removeItem(at: url)  // 日志只留最近的一段
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func stop() {
        setCancelled(true)
        cancelLock.lock(); pauseRequested = false; cancelLock.unlock()
        paused = false; playbackMark = nil
        player?.stop()
        clearAudioCache()
        if busy {
            status = "正在停止…"
        }
    }

    func releaseIdleModels() {
        guard !busy else { return }
        engine = nil; bertEngine = nil; frontend = nil
    }

    /// Large model files are copied off the UI thread and never during inference.
    func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        busy = true; status = "正在导入文件…"; player?.stop()
        worker.async { [weak self] in
            guard let self else { return }
            var failure: String?
            do { for url in urls { try ReaderVoiceFiles.importFiles(url) } }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = false; self.releaseIdleModels(); self.refresh()
                self.status = failure ?? "文件已导入"
            }
        }
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func setCancelled(_ value: Bool) {
        cancelLock.lock()
        cancelRequested = value
        cancelLock.unlock()
    }

    /// 文件夹里有东西，它才会出现在「文件」App 和 iTunes 的文件共享里。
    private static func writeGuide(in docs: URL) {
        let guide = docs.appendingPathComponent("使用说明.txt")
        let text = """
        把电脑上 gsv-ipad\\work\\ipad 里这些文件拷到这里（放不放在文件夹里都可以）：
          models  7 个模型文件（约 570MB），必须有
          voices  电脑上做好的角色包（.gsvpack），可选
          voice   在 iPad 上加角色要用的 4 个文件（约 350MB），可选
          bert    中文语调模型 roberta_fp16.onnx（约 570MB），可选，读中文时语气更自然
        拷完回到 App，会自动重新检查。
        在 iPad 上加角色用的录音也可以拷到这里；录音旁边放一个同名的 .txt，写上录音里说的话，会自动填好。
        在 iPad 上加的角色保存在 voices 文件夹。
        朗读音频只在播放队列中临时保留，播放或停止后自动清理；outputs\\log.txt 是最近的日志。
        """
        if (try? String(contentsOf: guide, encoding: .utf8)) != text {
            try? text.write(to: guide, atomically: true, encoding: .utf8)
        }
    }
}
