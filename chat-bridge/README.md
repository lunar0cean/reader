# 页间 × ChatGPT 连接服务

这是第一阶段的连接验证实现：App → Workers / D1 → MCP Events → ChatGPT Work → 插件回传 → App。没有模型 API、模型 API Key 或隐藏网页自动发消息。网页只提供登录和查看对话的入口。

**2026 年 10 月 5 日已部署到用户的免费 Cloudflare 账号；GitHub OAuth 凭证已加密保存，公网健康检查为 `configured: true`。用户的 Chrome 已成功创建并授权私人 MCP，发现四个工具及 `message.created` 事件，并在网页 Work 调用诊断请求。App 正式授权和真实 ChatGPT 十轮验收未完成，完整 room 场景尚未接入。** 本地测试使用真实 Workers 运行时、D1、OAuth Provider 和签名协议；模型回复在测试中模拟，不能证明账号支持或回复速度。

当前服务根地址：`https://yejian-chat-bridge.hilariobrehmer242.workers.dev`；私人 MCP 地址为根地址加 `/mcp`。部署结果和未完成事项见 [部署记录](DEPLOYMENT.zh-CN.md)。

此前内嵌浏览器拒绝私人 MCP 创建且安全设置加载失败；改用用户本人 Chrome 后已完成创建、OAuth 自动发现和 GitHub 身份授权。插件 ID 为 `plugin_asdk_app_6ac3926f076081919271f77afbf0af1e`，不应重复创建同名连接。事件发现与实际订阅分别验收，不能把普通工具调用当成自动消息闭环。

## 本地开发

需要 Node.js 22 或更新版本。在 Windows PowerShell 中使用 `npm.cmd` / `npx.cmd`。

```powershell
cd D:\ios\reader\chat-bridge
npm.cmd ci
npm.cmd run check
npm.cmd test
npm.cmd run build
```

`build` 只做部署打包检查，不上传。`npm.cmd run db:local` 后可用 `npm.cmd run dev` 检查本地健康页。iPad 和 ChatGPT 的正式验证需要公网 HTTPS 地址。

## 首次部署：一次电脑设置，之后 iPad 独立使用

1. 注册 [Cloudflare 账号](https://dash.cloudflare.com/sign-up)，选择免费 Workers；设置 `workers.dev` 子域名。运行 `npx.cmd wrangler login`，在浏览器中本人登录并授权。无需把密码发送给 Codex。
2. 创建存储，保留命令返回的资源 ID。如果已创建，使用 `wrangler d1 list` / `wrangler kv namespace list` 找到已有资源，避免重复创建。

```powershell
npx.cmd wrangler d1 create yejian-chat --location apac
npx.cmd wrangler kv namespace create OAUTH_KV
```

3. 将实际根地址、D1 UUID、KV ID 写入配置。下面的占位内容需替换成上一步的值；脚本会拒绝占位 ID。`configure` 不创建资源或上传内容。

```powershell
npm.cmd run configure -- --origin https://yejian-chat-bridge.你的子域.workers.dev --database-id 实际D1_UUID --kv-id 实际KV_ID --owner lunar0cean
```

4. 在 [GitHub OAuth Apps](https://github.com/settings/developers) 创建私人 OAuth App。主页为上述服务根地址；回调为 `https://yejian-chat-bridge.你的子域.workers.dev/github/callback`。仅请求 `read:user`，不需要访问私有仓库。生成 Client Secret 后，在终端的隐蔽输入中保存；不要写进 Git、截图、部署日志或聊天。

```powershell
npx.cmd wrangler secret put GITHUB_CLIENT_ID
npx.cmd wrangler secret put GITHUB_CLIENT_SECRET
npm.cmd run db:remote
npm.cmd run deploy
```

5. 浏览器访问服务的 `/health`，应显示 `configured: true`、`modelAPI: false`。未授权访问 `/api/status?sessionId=room-default` 应返回 401。`/.well-known/oauth-protected-resource` 应指向本服务授权地址。

`wrangler secret put` 在服务未创建时可能提示创建 Worker，这是首次部署的一部分。D1 / KV ID 不是登录凭证，OAuth Secret 只放 Workers Secrets。默认只允许 `lunar0cean` 使用，实际本人用户名不同时必须修改。

## iPad 与 ChatGPT 首次连接

本机 Windows 免费签名和已有插件连接的逐步操作见 [首次安装说明](../ipad-reader/docs/INSTALL.zh-CN.md)。

1. 安装本次未签名 IPA 的**个人免费签名版本**。未签名文件不能直接安装；首次侧载和续签仍需实机验证。阅读器无需连接服务也能读书、批注和使用笔记本。
2. 阅读器「更多 → 连接 ChatGPT → 服务与角色设置」填写服务根地址。第一版保持会话 `room-default`、角色 `room-companion`；保存设置后点「使用 GitHub 授权」。系统认证窗口返回 App，凭证保存到 Keychain。
3. 在 Safari 打开同一 ChatGPT 账号，使用已安装的「页间私人连接」。首次创建时，从「插件 → 添加 → 创建自定义 MCP 服务器」填写服务根地址加 `/mcp`，选择 OAuth 并完成 GitHub 授权。Chrome 已验证该入口；iPad Safari 的菜单和权限仍以实际账号为准，不要求更改安全设置。缺少 Work / Events 能力时，记录诊断并停止自动触发路线。
4. 创建 **Work 对话，使用云端执行环境**，添加页间连接。复制 App 的「Work 设置提示词」到这条对话。确认订阅 `message.created`，过滤会话和角色 ID，关闭批处理。首次订阅是否需要额外确认，由 ChatGPT 实际权限决定。
5. 在 App 中检查连接，状态应变为「可用」。发送一句话，Work 应调用 `get_context`，随后调用 `publish_reply`；只在 ChatGPT 页面显示文字不会回传到 App。
6. 收起聊天网页，保持 App 前台，运行十轮真实验证。导出诊断并填写 [验收表](../ipad-reader/docs/CHAT_ACCEPTANCE.zh-CN.md)。页面关闭、网络切换、授权撤销也要分别验收。

私人 MCP 连接足以先验证闭环；`plugin/` 另提供可移植插件和角色 skill。部署配置脚本会更新其 MCP 地址。可用的本地 / 仓库插件安装来源因 ChatGPT 表面而异；iPad 应优先走网页中的私人 MCP 设置。需要绑定已注册连接时，使用实际 `plugin_asdk_app...` ID，不能用占位 ID 假装安装完成。参见 [官方连接步骤](https://developers.openai.com/plugins/deploy/connect-chatgpt) 和 [插件打包格式](https://developers.openai.com/plugins/build/plugins)。

## 数据与恢复

- App 主动勾选「发送当前页原文」后才共享原文；原书、插图、完整手写文件留在本机。当前支持文字书摘，扫描页 / 手写 OCR 后续接入。
- 问题在发网请求前写入本地。相同请求 ID 重发不产生新问题；同一问题每种结果只接受第一条。
- App 前台等待每 2 秒取回复，空闲每 30 秒，系统后台停止。启动 / 返回前台补取；收到回复后先保存本机，再确认游标。
- 一分钟超时只是状态提示，迟到回复仍归到原请求。十轮验证使用 App 实际接收时间计时，另外保留服务耗时。
- 引用 ID 从本次共享书摘解析回本机 `SourceAnchor`，不信任模型提供的坐标。保存到书籍或笔记本后保留引用、角色和回复来源；旧笔记仍可解码。书籍 Markdown、原生备份和笔记页 SVG 元数据保留出处。
- 切换服务地址不会将旧待发送问题发给新服务。本地聊天记录保存为 `Documents/chat-transcript.json`，凭证不写入该文件或诊断。聊天网页有单独的持久化 WebKit 数据存储；它的登录会话不替代 App 授权。
- 默认订阅最多一天，ChatGPT 按 `refreshBefore` 续订；签名密钥变更有短暂双签名窗口。授权撤销后不再投递对应客户端订阅；回调 410 / 413 停止重试。官方 Webhook 的 2xx 只表示接收，模型处理仍为异步。

## 接口

| 接口 | 用途 |
| --- | --- |
| `POST /api/sessions` | 创建或更新会话；一个会话绑定一个角色 |
| `POST /api/messages` | 创建问题并安排事件投递 |
| `GET /api/status?sessionId=…` | 授权后查询订阅、待回复和投递错误 |
| `GET /api/results?sessionId=…&after=…` | 按单调游标补取回复与草稿 |
| `POST /api/ack` | 确认已落盘的游标 |
| `POST /mcp` | MCP 2.0 发现、事件方法、四个工具；兼容旧工具初始化 |

MCP 工具为 `get_context`、`read_excerpts`、`publish_reply`、`create_note_draft`。消息事件只有用户问题触发，回复不会反向触发循环。回调主机默认限制到 OpenAI 官方域名，配合 Workers 的 `global_fetch_strictly_public` 禁止私网目标和跳转；如实际官方回调不在列表，应核实后明确更新配置。

## 费用和当前限制

本实现不启用付费模型 API，也不升级 Cloudflare 套餐。按 2026 年 10 月 5 日核对的官方价格，Workers 免费额度为每天 100,000 次请求、每次 10 ms CPU；付费方案为每个账号每月 5 美元起，包含每月 1,000 万次请求和 3,000 万 CPU 毫秒，超出后分别按每百万请求 0.30 美元、每百万 CPU 毫秒 0.02 美元计算。[Workers 定价](https://developers.cloudflare.com/workers/platform/pricing/)

D1 免费包含每天 500 万行读取、10 万行写入及合计 5 GB 存储；KV 免费包含每天 10 万次键读取、1,000 次键写入、1 GB 存储。免费额度用尽后相关操作会失败，不会因为本程序自动购买付费套餐。[D1 定价](https://developers.cloudflare.com/d1/platform/pricing/)、[KV 定价](https://developers.cloudflare.com/kv/platform/pricing/)

单人文字消息量预计可落在免费额度内，这只是估算。每 2 秒查询 1 小时产生约 1,800 次取回复请求；空闲每 30 秒查询 1 小时约 120 次，另有状态、授权、订阅和事件请求。OAuth 加密与密钥校验的 CPU、KV 写入及数据库扫描量仍需真实使用后记录；超限时先报告证据，再由用户决定是否升级。ChatGPT 的账号权益与额度另外核验，Cloudflare 费用不包含模型订阅。

官方 MCP Events 当前要求支持的 Work 环境；账号权益、工具确认、持续订阅和一分钟响应不是本程序可以保证的能力。[MCP Events 文档](https://developers.openai.com/plugins/build/mcp-events)
