# 页间 · 原生 iPad 阅读器

私人使用的阅读器，先把「读书 → 写在书页上 → 提问 → 回到出处 → 保留笔记」做顺手。

## 这一版可以做什么

| 功能 | 浏览器交互预览 | SwiftUI 原生 V0.8 |
| --- | --- | --- |
| 书库、目录、书签、专注阅读 | 已实现 | 已实现 |
| 全屏暖纸、覆盖式工具栏、横屏双页／竖屏单页 | 已实现 | 已实现 |
| UTF-8 TXT 导入 | 已实现 | 已实现 |
| UTF-8 Markdown 导入、标题／列表／代码排版及出处 | 未接入 | 已实现 |
| 统一书库的独立笔记本、单本可编辑文件 | 旧工作区入口 | 已实现 |
| 可重排 EPUB · 章节、目录、正文、常见插图 | 已实现 | 已实现 |
| PDF · 原页面、旋转、裁切、文字页与无文字页 | PDF.js | PDFKit／Core Graphics |
| 基础 PPTX 文字和图片、固定页、保留原件 | 未接入 | 已实现，复杂版式建议导出 PDF |
| 正文长按选择、端点拖动、复制 | 未接入 | TXT／EPUB／MD／网页／PDF 文本层 |
| 插图双击打开／关闭、缩放、复制和分享 | 未接入 | EPUB／网页位图与 PDF 图片对象 |
| 书页直接角色朗读、设置管理模型与角色 | 未接入 | 中文／日文，保留导入及录音创建角色包 |
| 原书封面、PDF／PPTX 首页封面、自定义图片封面 | 未接入 | 已实现，封面随可编辑备份保留 |
| HTML／公开 HTTPS 网页 · 离线正文与可获取插图 | 已实现，URL 受 CORS 限制 | 已实现 |
| 字体、字号、粗细、对齐、行距、留白、暖纸／棕褐／夜读 | 已实现 | 已实现 |
| 连续跨页笔迹、荧光笔、橡皮、撤销／重做、隐藏 | 单一 SVG 画布 | 单一 PencilKit 画布 |
| 滑动翻页、侧栏动画、整页双指缩放（不重排） | 旧版手势 | 已实现，云端界面测试通过 |
| 顶部笔工具、任意 RGB 与笔宽、笔写画／手指导航 | 旧版工具条 | 已实现，云端界面测试通过 |
| 文字笔记、编辑、删除、原文定位 | 页内文字与侧栏 | 侧栏文字笔记 |
| 回答展示、点击出处、保存为笔记 | 本地摘录演示 | 本地摘录演示 |
| Markdown 与可编辑备份导出、恢复 | 已实现 | 已实现 |
| 仅笔迹层导出 | 透明 SVG | 透明 PNG、全书笔迹 PDF |
| 原文＋笔迹 PDF、仅笔迹 PDF | 当前展开页浏览器打印 | 全书导出 |
| 原文件／网页 HTML 导出，备份包含原文件与插图 | 已实现 | 已实现 |
| 登录／动态网页、在线小说章节抓取 | 后续实现 | 后续实现 |
| 真实 AI 问答、OCR、3D 书房 | 后续实现 | 后续实现 |
| 笔记本／分区／页面、可收起目录与工具栏 | 已实现 | 书库选笔记本；页栏／分区栏逐级展开 |
| 左上固定、向右下自动扩展的自由画布 | SVG 压感点列 | PencilKit 压感画布 |
| 独立笔记页文字、图片、手写；对象移动缩放 | 已实现 | 已实现 |
| 笔记页 SVG 可编辑恢复、完整笔记本 JSON | 共用笔记本格式 | 共用笔记本格式 |
| ChatGPT 插件授权、离线发件箱、回传引用与笔记 | 未接入 | 验证实现，待云端与真实账号验收 |

**AI 面板当前是可交互的本地原文摘录演示，不会调用模型，也不发送书籍内容。** 原创示例书用于演示 UI。旧每日英语模块不再是阅读器的内容来源。

V0.6 原生 App 默认进入书库，笔记本与其他书籍并列，可直接新建或打开，退出回书库。笔记本无需从某本书的菜单进入，原有数据继续保留；单本导出为 `.yejiannotebook`。PDF 翻页移入的页直接成为正式页，阅读进度在后台编码；侧栏按速度跟手收起，笔记画布扩展保留缩放和滚动位置。操作与测试记录见 [阅读与书写手势](docs/READING_FEEL.zh-CN.md)。ChatGPT 状态仍为待订阅，事件连接排查暂时暂停。

V0.7 修复书架仍显示书籍专用栏；加入正文选择复制和图片放大复制。笔记书写期间暂停掌托可能触发的外层缩放，笔迹保存移到后台，不再每次遍历整页旧笔迹。朗读复用 [gsv-ipad 固定源码](Voice/INTEGRATION.md)，角色包可导入或在设备上用录音创建；模型和角色资源仅在本地附加到 IPA，不提交 GitHub，不需要模型 API。

V0.8 点书页顶部扬声器直接朗读，再点停止；模型、角色和参数统一放到「朗读设置」，不再打开独立朗读页。生成音频只用于流式播放，不保留完整 WAV；停止、完成与进入后台清理生成缓存，保留角色录音和模型。插图改为双击打开、双击关闭，纯图片 PDF 不出现文字复制选区。笔记本在主界面切换，修复反复打开其他笔记本时退出的问题；导航按钮依次展开页栏、分区＋页栏、全部收起，内容和侧栏向左滑可收起。最近三个笔记页保留画布、撤销与缩放位置，顶栏使用阅读器同一青色。

PDF 和 PPTX 使用第一页封面，EPUB 优先使用书内声明封面；没有可用封面时显示生成封面。在书库长按书籍或笔记本，选择「更换封面」，可从照片或本地文件选择图片，也可恢复默认封面。自定义封面和原书封面随备份保留，旧备份仍能读取。

2026-10-09（北京时间），[macOS 构建 #60](https://github.com/lunar0cean/-/actions/runs/37807199379) 的设备与模拟器编译成功，A16／iPadOS 18.5 模拟器的 42 项单元测试、8 项界面测试全部通过，对应原生源码 `29202dcdd65daf8da959f29b37c91ba4ca3cee38`。覆盖连续切换笔记本、页缓存中的真实笔迹与缩放位置、扫描 PDF 长按、图片双击开关、PDF／EPUB 封面与备份，以及原有复制、分页、跨页笔迹和格式导入。真实 Pencil 手感、完整 ONNX 合成与新增角色仍需本人 A16 实测。

书库右上连接图标或「更多 → 连接 ChatGPT」是单独的真实连接验证入口，使用私人 MCP / Events，无模型 API Key。需要先部署 [`chat-bridge`](../chat-bridge/README.md) 并在支持事件订阅的 Work 对话授权；未配置时不上传内容。可以主动共享当前页、保存回传为书籍 / 笔记本笔记、点引用回原文。完整 3D 书房按计划等待 [真实十轮验收](docs/CHAT_ACCEPTANCE.zh-CN.md) 通过后接入。

## 在 Windows 立即看 UI

通过本地服务器打开预览；EPUB 和 PDF 使用本地模块与 worker，不能直接双击 HTML：

```powershell
cd D:\ios\reader\ipad-reader\Preview
python -m http.server 8877 --bind 127.0.0.1
```

访问 <http://127.0.0.1:8877>。默认正文为系统黑体，可选宋体已打包在本地，EPUB／PDF 引擎也已打包，无 CDN。只有主动添加网页网址时才请求网页及其插图。若端口被占用，换一个空闲端口。

书页背景铺满阅读区，纸感来自暖纸色与排版。竖屏单页，横屏双页，没有书封、书脊或纸张厚度。青色顶栏和底部进度条覆盖在书页上，显示／隐藏不改变排版；单击书页中间隐藏或恢复工具栏，左右滑动和方向键翻页。目录为独立深灰界面，设置为右上浮层，AI／笔记按需打开且不挤压正文。

以下为浏览器预览的操作路径，原生 V0.6 从书库直接打开独立笔记本：

1. 左上返回书库，或在右上「更多」中导入 EPUB、PDF、TXT 或 HTML；「更多 → 添加网页文章」可保存 HTTPS 文章。
2. 点一个笔图标展开批注工具；再点一次退出并收起，已有笔迹继续显示。
3. 横屏可以一笔从左页划到右页；旋转到竖屏后分别查看和编辑同一笔的两部分。橡皮删除整笔，撤销／重做以整笔为单位。
4. 阅读助手中提问，点击引用回到原文；保存摘录时一并保存出处。
5. 「更多 → 导出与备份」保存 Markdown、当前页笔记层或完整 JSON；导入 JSON 恢复可编辑状态。
6. 「更多 → 笔记本模式」进入独立自由画布，按笔记本、分区和页面整理文字、手写与图片。左上固定，向右下延伸，目录和工具栏可隐藏。详情见 [笔记本模式说明](docs/NOTEBOOKS.zh-CN.md)。

预览优先使用 IndexedDB 保存书库和原文件，小书库兼容旧 localStorage。换浏览器或清除站点数据不会自动同步。**阅读器书库的预览备份和原生备份目前是不同格式**：预览用 SVG 点列；原生保留完整 `PKDrawing` 数据。新增笔记本工作区的 SVG／JSON 则使用同一套笔记本格式，可以分别导入；它与书库备份是不同文件。

## 原生工程与云编译

`Native/` 使用 SwiftUI、CoreText 和 PencilKit；最低部署目标 iPadOS 17，界面按 iPad 设计。项目由 `project.yml` 生成：

```sh
cd ipad-reader
brew install xcodegen
xcodegen generate
xcodebuild -project YeJian.xcodeproj -scheme YeJian \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

仓库 `.github/workflows/ipad-reader.yml` 在相关 PR 和手动运行时使用 macOS 编译模拟器 App 与未签名 IPA，并执行原生字体、分页、旧版式兼容、格式导入、网页图片保存、备份、PDF 导出、横竖屏及跨页手写检查和截图。它不调用邮箱、旧英语脚本或任何 AI 密钥。`YeJian-unsigned-build` 单独保留 IPA，`YeJian-simulator-app` 保留调试 App，原生截图另存，安装时无需下载模拟器文件。

未签名 IPA **还不能直接装到 iPad**。个人免费签名、Windows 侧载工具、续签和你提供的 A16／iPadOS 26.7 组合，需要在设备上另外验证；云编译通过只代表工程能构建。

## 笔迹定位的当前取舍

无笔迹的新书按阅读区尺寸排版；写下笔迹后保留逻辑页尺寸与版式。横屏为连续的左右双页画布，竖屏裁切展示其中一页，两种方向使用同一份 `PKDrawing`／SVG 点列。跨页笔画不会分裂成两笔，旋转只改变展示数量和统一缩放，不迁移或截断笔画。

原生备份 V3 使用 `engine=native-pencilkit-v3`，按两页原文 UTF-16 起点组成的键保存 `spreadDrawings`；浏览器备份 schema 3 使用 `spreadInk` 与 `pageSize`。两者均可导入自己的旧 V1／V2 备份：旧字体、分页和笔迹位置保留，右页笔迹平移至连续画布，擦除后不会从旧数据复活。跨引擎备份仍不能互相导入。

**已有手写笔迹的书籍暂锁定字体、字号、行距、对齐和留白**，仍可换背景和随屏幕方向缩放。这是为了保留圈画的原文位置。完整方案见 [开发规划](docs/PLAN.zh-CN.md)：原版式快照保留，未来重排建立新版本，并用原文锚点迁移可定位的批注。

## 格式实现和当前边界

- **Markdown**：UTF-8 `.md` / `.markdown` 使用 Swift Markdown 与 swift-cmark 解析标题、列表、引用、代码和行内样式，原始字节与段落样式一起保存。表格按行展示，图片暂显示替代文字，数学公式与 Mermaid 保留源码。当前仅原生版支持。
- **EPUB**：固定版本 ZIPFoundation 解包，XML 解析 `container.xml`、OPF manifest／spine，按 spine 阅读顺序取章节；EPUB 3 nav 和 EPUB 2 NCX 提供章名。SwiftSoup 提取正文与常见位图插图，CoreText 实际测量分页；预览使用本地 fflate、DOM 与同一数据结构。原 EPUB 字节一并保存。采用统一阅读版式，尚不还原出版者 CSS、复杂表格、公式、音视频和互动；固定版式与 DRM 书籍明确拒绝。
- **PDF**：PDFKit 解析文档与文字，Core Graphics 按原 crop box 和 rotation 绘制页内容及原注释；无文字页仍完整显示，可手写但需后续 OCR 才能文字检索。竖屏单页、横屏双页，使用稳定的逻辑坐标；字体和留白设置不改变 PDF 原件。预览使用本地 PDF.js，包含 CMaps 和标准字体。
- **网页**：HTTPS URLSession 下载公开静态 HTML，SwiftSoup 优先提取 article／main，过滤导航与脚本；保存 HTML 原件、来源、时间和可下载的 PNG／JPEG／GIF／WebP 插图。也可导入 HTML，支持其中的内嵌位图。图片失败显示替代说明。不会执行原网页脚本。浏览器预览通过 fetch 获取内容，源站 CORS 限制时可改导入 HTML。
- **定位**：EPUB 记录章节 href＋段落＋UTF-16 偏移；PDF 记录真实页号＋可提取原文；网页记录来源 URL＋段落＋原文快照。引用、书签与笔记共用此定位。已有手写仍保留原版式；尚无跨出版版本自动迁移或 EPUB CFI。
- **备份／导出**：V3 JSON 包含原文件、离线插图、正文、版式、完整可编辑笔画和定位，向后读取 V1／V2。原生可导出全书原文＋笔迹 PDF、仅笔迹 PDF、当前页透明 PNG、Markdown 和原文件。分享 PDF 的笔迹为图像，继续编辑需保留 JSON。

当前导入单文件上限 50 MB，备份导入上限 200 MB；PDF 最多 2000 页；EPUB 解压总量不超过 100 MB。网页 HTML 上限 5 MB，最多取 12 张外部图片、每张不超过 2 MB、总量不超过 12 MB。基础 PPTX 可直接导入，复杂 PPTX 和旧 PPT 建议导出 PDF。登录页面、动态网页、分页小说抓取和 OCR 尚未接入。

格式检查：`scripts/check_formats.cjs` 验证 EPUB 章节顺序与插图、PDF 文字页／无文字页／旋转裁切、跨页批注、出处、原文件备份恢复、网页及图片保存、大文件 IndexedDB 恢复。`Resources/Fixtures` 为原创测试样本。

实现与数据关系见 [格式实现说明](docs/FORMATS.zh-CN.md)。

## 字体许可

本地正文使用 [Noto Serif SC](https://github.com/google/fonts/tree/main/ofl/notoserifsc) 的 400 字重静态派生字体，内部名称为 Yejian Serif。TTF 用于原生，WOFF2 用于预览，二者保留相同字形与度量；完整许可位于 `Resources/Fonts/OFL.txt` 和 `Preview/assets/OFL.txt`。重新生成时下载官方 `NotoSerifSC[wght].ttf` 到 `Resources/Fonts/NotoSerifSC.ttf`，安装 `fonttools`、`brotli` 后运行 `scripts/prepare_font.py`。

## 结构

```text
ipad-reader/
  Native/          原生界面、分页、笔迹、状态、导入与导出
  Resources/       原创示例书与原生书库数据
  Preview/         离线可交互的 UI 预览
  scripts/         生成示例书库、验证预览
  docs/            开发规划、Claude 3D 协作接口
  project.yml      XcodeGen 工程定义
```

刷新示例数据：`python ipad-reader/scripts/build_library.py`。预览检查脚本 `scripts/check_preview.cjs` 需要 Playwright；可通过 `PLAYWRIGHT_MODULE` 指向现有包，并通过 `BROWSER_EXECUTABLE` 指向测试浏览器。

本地 `D:\ios\room3d` 保留 Claude 制作的场景，当前没有打进原生 App，也没有被本次清理触碰。

原生依赖固定为 ZIPFoundation 0.9.20（MIT）、SwiftSoup 2.8.3（MIT）、Swift Markdown 0.5.0 与 swift-cmark 0.5.0（Apache 2.0 / Swift 运行库例外）；预览使用 fflate 0.8.2（MIT）与 PDF.js 4.10.38（Apache 2.0）。源码来源和完整许可见 `Preview/vendor`、依赖仓库及格式实现说明。
