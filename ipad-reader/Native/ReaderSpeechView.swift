import SwiftUI
import UniformTypeIdentifiers

struct ReaderSpeechView: View {
    @EnvironmentObject private var voice: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var adding = false
    @State private var deleting: VoicePreset?
    var body: some View {
        NavigationStack {
            Form {
                Section("按原文语言自动选择") {
                    Picker("原文语言", selection: $voice.languageMode) { Text("自动识别").tag("auto"); Text("中文").tag("zh"); Text("日文").tag("ja") }
                    if voice.presets.isEmpty { Text("添加一个角色包，或用录音创建角色。") }
                    else {
                        Picker("中文角色", selection: $voice.chineseVoice) { ForEach(voice.presets) { Text($0.name).tag(Optional($0.url)) } }.accessibilityIdentifier("speech-chinese-voice")
                        Picker("日文角色", selection: $voice.japaneseVoice) { ForEach(voice.presets) { Text($0.name).tag(Optional($0.url)) } }.accessibilityIdentifier("speech-japanese-voice")
                    }
                    Text("中文和日文分别记住角色。角色包的录音语言会显示在管理列表中。") .font(.footnote).foregroundStyle(.secondary)
                }.disabled(voice.reading)
                Section("阅读时播放") {
                    HStack { Text("语速"); Spacer(); Text(String(format: "%.2f ×", voice.rate)).monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $voice.rate, in: 0.75...1.5, step: 0.05).accessibilityLabel("朗读语速")
                    Toggle("高亮正在朗读的句子", isOn: $voice.highlightEnabled)
                    Toggle("音频增强", isOn: $voice.enhance).disabled(voice.reading)
                    Text("点书页扬声器开始，点暂停后可从当前音频位置继续；退出阅读后保留句子位置。") .font(.footnote).foregroundStyle(.secondary)
                }
                Section("管理角色") {
                    ForEach(voice.presets) { preset in
                        HStack {
                            Image(systemName: "person.wave.2").foregroundStyle(ReaderPalette.link)
                            VStack(alignment: .leading) { Text(preset.name); Text(preset.language == "ja" ? "日文参考录音" : "中文参考录音").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button { deleting = preset } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("删除角色 " + preset.name).disabled(voice.reading)
                        }
                    }
                    Button("导入角色包 / 模型", systemImage: "square.and.arrow.down") { importing = true }.disabled(voice.busy)
                    Button("用录音添加角色", systemImage: "person.badge.plus") { adding = true }.disabled(voice.busy)
                }
                if !voice.modelsReady {
                    Section("准备离线朗读") {
                        Text("可从「文件」导入模型文件夹，或用电脑「Apple 设备 → 文件 → 阅读器」传入模型。")
                        ForEach(voice.missingFiles, id: \.self) { Text($0).font(.caption.monospaced()) }
                        Button("重新读取文件") { voice.refresh() }
                    }
                }
                Section("播放与缓存") {
                    Text("返回书页，点击上栏的扬声器即可朗读；选中文字后也可直接朗读选区。")
                    Text("临时音频在播放或停止后自动清理，不保留整页录音。模型与角色包会保留。")
                    if !voice.status.isEmpty { Text(voice.status).font(.footnote).foregroundStyle(.secondary) }
                    Button("清理朗读音频缓存") { voice.stop(); voice.clearAudioCache() }
                }
            }.navigationTitle("朗读设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(isPresented: $adding) { ReaderAddVoiceView() }
                .confirmationDialog("删除角色「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                    Button("删除角色", role: .destructive) { if let deleting { voice.delete(deleting) }; deleting = nil }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .folder], allowsMultipleSelection: true) { result in
                    do { voice.importFiles(try result.get()) }
                    catch { voice.status = error.localizedDescription }
                }
                .scrollContentBackground(.hidden).background(ReaderPalette.panel)
                .toolbarBackground(ReaderPalette.sage, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        }.tint(ReaderPalette.link).preferredColorScheme(.dark).accessibilityIdentifier("reader-speech")
    }
}

struct ReaderAddVoiceView: View {
    @EnvironmentObject private var voice: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transcript = ""
    @State private var language = "zh"
    @State private var audio: URL?
    @State private var importedAudio: URL?
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                if !voice.voiceModelsMissing.isEmpty {
                    Section("添加角色所需模型") {
                        Text("请先导入原 GPT Sovits 的 voice 文件夹，再用录音创建角色；已有 .gsvpack 角色包仍能直接导入。")
                        ForEach(voice.voiceModelsMissing, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }
                Section("参考录音") {
                    Text("建议使用只有一个人在说话的 3–10 秒录音。")
                    Button(audio?.lastPathComponent ?? "选择录音") { importing = true }.disabled(voice.busy)
                    ForEach(voice.recordings, id: \.self) { url in Button(url.lastPathComponent) { audio = url; transcript = voice.transcript(for: url) ?? ""; if name.isEmpty { name = url.deletingPathExtension().lastPathComponent } }.disabled(voice.busy) }
                }
                Section("角色") {
                    TextField("角色名称", text: $name)
                    Picker("录音语言", selection: $language) { Text("中文").tag("zh"); Text("日文").tag("ja") }
                    TextEditor(text: $transcript).frame(minHeight: 130).accessibilityLabel("录音里的原话")
                    Text("填写录音里的原话，保持一致。")
                }.disabled(voice.busy)
                Section {
                    Button("生成角色包") {
                        guard let audio else { return }
                        voice.addVoice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), language: language, audio: audio, transcript: transcript) { success in if success { dismiss() } }
                    }.disabled(voice.busy || audio == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !voice.voiceModelsMissing.isEmpty)
                    if voice.busy { ProgressView() }
                    Text(voice.status).font(.footnote)
                }
            }.navigationTitle("添加朗读角色").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(voice.busy) } }
                .scrollContentBackground(.hidden).background(ReaderPalette.panel)
                .toolbarBackground(ReaderPalette.sage, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .interactiveDismissDisabled(voice.busy)
                .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                    do {
                        let url = try result.get(), scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
                        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: destination)
                        if let importedAudio { try? FileManager.default.removeItem(at: importedAudio) }
                        importedAudio = destination; audio = destination
                        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    } catch { voice.status = error.localizedDescription }
                }
        }.tint(ReaderPalette.link).preferredColorScheme(.dark)
            .onDisappear { if let importedAudio { try? FileManager.default.removeItem(at: importedAudio) } }
    }
}

enum ReaderVoiceFiles {
    static func importFiles(_ url: URL) throws {
        let scope = url.startAccessingSecurityScopedResource(); defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let files: [URL]
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        } else { files = [url] }
        let names = Set(SynthEngine.modelFiles + [BertEngine.fileName, "hubert.onnx", "sv.onnx", "prompt_encoder_fp32.onnx", "prompt_encoder_fp32.bin"])
        var imported = 0
        for file in files {
            let role = file.pathExtension.lowercased() == "gsvpack"
            guard role || names.contains(file.lastPathComponent) else { continue }
            if role { try TensorPack(url: file).validateVoice() }
            let subfolder = role ? "voices" : file.lastPathComponent == BertEngine.fileName ? "bert" : ["hubert.onnx", "sv.onnx", "prompt_encoder_fp32.onnx", "prompt_encoder_fp32.bin"].contains(file.lastPathComponent) ? "voice" : "models"
            let folder = AppModel.documents.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Import as a new role; never overwrite an existing editable voice.
            var destination = folder.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path), role { destination = folder.appendingPathComponent("import-\(UUID().uuidString).gsvpack") }
            if file.standardizedFileURL == destination.standardizedFileURL { continue }
            let staging = folder.appendingPathComponent(".import-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: destination) }
            imported += 1
        }
        guard imported > 0 else { throw ReaderFileError.invalid("请选择 .gsvpack 角色包、GPT Sovits 的模型文件或模型文件夹。") }
    }
}
