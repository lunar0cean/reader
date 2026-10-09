# EPUB、PDF、Markdown 和网页阅读实现

## 数据流

```text
文件导入 / HTTPS URL
  → ReaderImport（校验、解析、保留原件）
  → ReaderBook（原件、正文、离线资源、来源和时间）
  → ReaderPagination / ReaderPDF（逻辑页和来源定位）
  → BookSurface（竖屏单页、横屏双页）
  → 单一 PencilSurface（整对页的 PKDrawing）
  → ReaderStore（笔记、出处、原件、版式和 V3 备份）
```

TXT、EPUB、Markdown 与网页共享可重排正文引擎；PDF 使用独立的固定页绘制路径。格式转换不会把原件替换成提取文字。阅读和批注仍是全屏页面和同一透明层。

## Markdown

原生导入 UTF-8 `.md` / `.markdown`，使用 Swift Markdown 0.5.0 与 swift-cmark 0.5.0 解析 CommonMark / GFM。标题、普通段落、嵌套列表、引用、代码块、粗体、斜体、行内代码与链接转换为稳定的显示文字和 UTF-16 样式范围，再由 CoreText 分页；标题不重复叠加书籍章名。表格当前按行展示，用分隔符区分单元格，未实现完整网格排版。

原始 Markdown 字节完整保存；段落样式与正文进入 V3 备份，引用指向显示段落及偏移，重排和恢复后仍可定位。图片暂显示替代文字，不自动抓取本地相邻文件或远程图片；嵌入 HTML 按文字显示，不执行。数学公式和 Mermaid 暂按源码呈现。浏览器预览本轮未新增 Markdown 导入。

## EPUB

`ReaderImport.epub` 用固定版本 ZIPFoundation 从内存读取归档，不将不可信路径写到磁盘。解压前校验条目大小、数量和总量。资源路径按章节所在目录解析，支持合法相对路径和 URL 百分号编码，拒绝越过归档根目录和外部 URL。

`META-INF/container.xml` 定位 OPF；manifest 建立资源索引，spine 决定实际顺序而非 ZIP 条目顺序。nav／NCX 提供章节标题。XML 不加载外部实体；HTML 由 SwiftSoup 解析，不执行脚本。

正文按语义块生成段落，常见位图成为带资源键的对象替换字符。`ReaderImages` 用 ImageIO 生成有限尺寸图像，CoreText run delegate 将图片的尺寸纳入分页；正文和图片因此共用原文范围，不把图片简单浮在错误的页上。

可调整统一字体、字号、行距和留白；不完全还原书中 CSS、复杂表格、数学公式和互动。暂拒绝固定版式 EPUB 和 DRM。字体混淆不当作正文 DRM，阅读使用自带字体。原 EPUB 一并备份，未呈现的资源仍可从原件找回。

## PDF

`ReaderImport.pdf` 用 PDFKit 校验文档、密码状态和页数，从每页提取可用文字。无文字页使用空的文本索引，但仍保留原 PDF 页面，不以“没有文字”删除页。

`ReaderPDF` 缓存原文档，缓存比较原字节，避免同一书籍 ID 恢复新原件时仍显示旧内容。阅读一页对应实际 PDF 一页；Core Graphics 根据 crop box 和页面 rotation 得到绘制变换，原注释也绘制到页面。

PDF 页按比例放进稳定的逻辑页尺寸，PencilKit 与页内容一起双指缩放。左右页仍共享连续笔迹：跨中线的一笔不会变成两个对象。翻页缓存前后页，移入页直接成为当前页，统一缩放和纸面位置。V0.7 支持长按选择有文本层的原文、拖动选择端点、复制／全选本页／朗读；使用 PDFKit 的文字范围和同一页变换定位。扫描页的 OCR 尚未实现。字体设置不重排 PDF。

## 文字和插图操作（V0.7）

TXT、EPUB、Markdown、网页的选择层使用正文同一 CoreText frame，长按选择文字，拖动端点扩展范围。文字位置和复制内容使用 UTF-16 范围，保留中文与 emoji；长按和端点拖动优先于翻页，普通手指拖动继续翻页／缩放。Pencil 的输入穿过选择层到独立笔迹层，开启批注后手指仍可选择正文。

EPUB／网页位图单点打开全屏图片页，可以双指放大、复制到系统剪贴板或分享。原始图片字节随书籍保存；PDF 的图片通过 XObject 与 Form 变换定位，再从原页面渲染裁切，保留 PDF 遮罩和颜色。不将任意矢量图形或扫描页内的局部图片误称为已提取对象。

## PPTX（V0.7）

基础 `.pptx` 可直接导入：按 presentation 关系读取顺序，把基本文字和图片绘制为可选择、可点图的固定 PDF 页，同时保留原 PPTX 和生成 PDF 进入备份。包内大小、数量、路径和页面尺寸均有限制；不执行宏，也不取得外部资源。

当前不完整还原母版、主题、图表、组合图形、SmartArt、OLE、旋转／裁切及动画。复杂演示文件应从 PowerPoint 导出 PDF 阅读；旧二进制 `.ppt` 仍需另存 PPTX 或导出 PDF。基础 PPTX 支持不等于完整 PowerPoint 排版兼容。

## 网页

输入完整 HTTPS 地址后使用临时 URLSession；不复用用户的浏览器登录态。请求限时和限量，校验状态、最终协议与 MIME。SwiftSoup 优先选择 article／main，去掉脚本、表单、导航与非正文元素，再生成独立的阅读数据。

原 HTML、最终 URL、导入时间、正文和可下载位图存入本机。外部图片仅接受 HTTPS，限数量与总大小；失败显示替代说明。HTML 文件可带内嵌位图。不会在阅读时重新运行网页脚本或依赖源站，因此原页面下线后仍可阅读已保存内容。

这不是带登录态的网页浏览器：依赖客户端脚本的正文、登录／付费页面、音视频、交互和小说章节抓取尚未实现。正文提取为基础的语义提取，并非完整 Readability 评分算法；复杂站点可能需要导出 HTML 或后续适配。

## 原文定位和手写

| 格式 | 当前定位 |
| --- | --- |
| TXT | 书籍 ID、章节、段落、UTF-16 偏移 |
| Markdown | 保留原始文件，显示段落与 UTF-16 偏移＋原文件名 href |
| EPUB | 上述定位＋spine 章节 href＋原文摘录 |
| PDF | 实际页号＋页内提取原文；可编辑笔迹在稳定逻辑坐标内 |
| 网页 | 来源 URL＋保存的正文快照＋段落、偏移和摘录 |

书籍 ID 区分每次导入的快照；同一份内容的备份沿用原 ID。尚不支持跨出版版本的定位迁移，也没有宣称任意 EPUB CFI 互通。无笔迹的正文可重新分页；有笔迹时锁定原版式，以保留圈画和原文关系。

## 保存与导出

原生 JSON V3（`native-pencilkit-v3`）包含原文件 Data、正文、插图资源、原文定位、版式和完整 PKDrawing，向后读取 V1／V2。浏览器 schema 3 保存相应原字节 base64 和 SVG 点列，优先使用 IndexedDB；两种引擎仍不能互相恢复。

原生导出全书原文＋笔迹 PDF、全书仅笔迹 PDF、当前页透明 PNG、文字 Markdown 和导入原文件。分享 PDF 中的笔迹为透明图像，原页面保留图文；需要继续编辑时使用 JSON。浏览器当前提供展开页打印、SVG、Markdown、原文件和完整备份。

## 验证

原生测试覆盖 EPUB spine 顺序、标题和插图、字符完整性、路径解析、网页正文与相对图片、内嵌图片、PDF 无文字页和页码、相同 ID 更换原件、带出处备份、合成 PDF 页数，以及 Markdown 样式、原始字节、重排字符完整性和出处恢复。UI 测试实际打开 EPUB、HTML、Markdown 和 PDF，并比较 PDF 正向、反向翻页后的纸面位置；连续跨页手写、撤销、重做和旋转保留仍执行。

浏览器脚本 `check_formats.cjs` 通过用户能操作的文件导入和网址入口验证格式、图像、原字节、搜索、出处、跨页笔迹、备份恢复，以及超过 localStorage 容量的 HTML 原件在 IndexedDB 中刷新恢复。网址测试使用受控响应，避免源站变更导致不稳定；源站本身的兼容性以实际导入结果为准。

## 依赖与参考

- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/0.9.20)：MIT；原生 EPUB ZIP 读取。
- [SwiftSoup 2.8.3](https://github.com/scinfu/SwiftSoup/tree/2.8.3)：MIT；原生 HTML 解析。
- [Swift Markdown 0.5.0](https://github.com/swiftlang/swift-markdown/tree/0.5.0)：Apache 2.0 / Swift 运行库例外；原生 Markdown 解析，固定 swift-cmark 0.5.0。
- [Apple PDFKit](https://developer.apple.com/documentation/pdfkit)：原生 PDF 文档、页与文本选择。
- [PDF.js 使用示例](https://mozilla.github.io/pdf.js/examples/)：预览 PDF 渲染，使用 `pdfjs-dist` 4.10.38（Apache 2.0），worker、CMaps、标准字体和许可全部本地保存。
- [fflate 0.8.2](https://github.com/101arrowz/fflate/tree/v0.8.2)：MIT；预览 EPUB 解包。

原生直接依赖由 Swift Package Manager 按精确版本解析；预览 vendor 文件从相应 npm 官方包提取，所有许可证随源码保存。目录和示例文件都是本项目原创测试数据。
