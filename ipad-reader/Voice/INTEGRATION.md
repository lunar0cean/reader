# 页间离线角色朗读

本模块移植自本人仓库 [lunar0cean/gsv-ipad](https://github.com/lunar0cean/gsv-ipad/tree/b7a079aac5f9762b5826261dde6f7e919924b6ea)，固定源码提交 `b7a079aac5f9762b5826261dde6f7e919924b6ea`。保留中文／日文文本处理、ONNX 推理、分句流式播放、音频增强和录音生成角色包；使用阅读器自己的界面。

## 使用

- 书库右上齿轮或书页「阅读设置 → 朗读设置」导入 `.gsvpack` 或模型文件夹，选择角色、语言与音频增强。
- 书页顶部扬声器直接读当前页；长按正文选择文字后点「朗读」也直接播放。再次点扬声器停止，整个操作留在原书页。
- 分句音频播放后释放，不再拼接并落盘整页 WAV；启动、开始/结束朗读、停止及进入后台均清理临时音频。仅清理 outputs 内的旧生成 WAV，不删除参考录音、模型或角色包。播放队列和停止均在主线程同步，停止后排除迟到片段。
- 「用录音添加角色」选择已有录音，填写与录音一致的原话和名称，生成新角色包。支持中文／日文；音频建议 3–10 秒。新角色写入 Documents/voices，立即加入选择列表。
- 导入新包不覆盖已有角色；删除随安装包提供的角色只隐藏该项。导入模型会清理旧推理缓存，避免继续使用旧权重。
- 本地推理不需要网络、模型 API 或 ChatGPT 事件订阅。原书、录音和角色包保留在设备。

## 文件与构建

`Frontend/` 为 JavaScript 文本处理和词典资源；`Japanese/` 为日文处理 Rust 源码。云构建为设备和模拟器分别编译日文静态库，再使用 ONNX Runtime 1.24.2 编译 Swift 模块。桥接头位于 `Native/gsv_native.h`。

模型、角色包和录音不提交 GitHub。App 从安装包 `VoiceModels/` 及自己的 Documents 递归发现文件，后者优先；也可通过「文件」或 Apple 设备的文件共享放入 Documents。

| 文件夹 | 内容 |
| --- | --- |
| models | t2s encoder、shared、first stage、stage decoder、vits 的 7 个 ONNX / bin 文件 |
| voices | `.gsvpack` 角色包 |
| bert | 可选 `roberta_fp16.onnx`，中文语调特征 |
| voice | 添加角色所需 hubert、sv、prompt_encoder_fp32.onnx 及同目录 bin |

`tools/package_voice_ipa.py` 在本机把原仓库 `work/ipad` 附加到已编译的未签名 IPA；所有文件流式写入，无需将 1.5 GB 数据同时放进内存。随模型 IPA 仍需个人签名安装。代码和模型来源声明见 [NOTICE.md](NOTICE.md)。

阅读／书写时不提前加载模型。合成串行后台运行；模型导入也在后台，新增角色前释放合成模型，语调模型在录音特征计算后释放，以减少 A16 内存峰值。

本轮检查文本前端、日文桥接和包结构；完整 ONNX 合成以及录音添加角色需要更新安装后在本人 A16 iPad 实测。上游的实机速度不作为本阅读器的实测结果。
