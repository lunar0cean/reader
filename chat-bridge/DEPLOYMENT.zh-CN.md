# Cloudflare 首次部署记录

日期：2026 年 10 月 5 日。使用用户本人 Wrangler OAuth 授权，保留免费套餐；没有购买服务、绑定付款方式或启用模型 API。

| 项目 | 已核对的结果 |
| --- | --- |
| 服务根地址 | https://yejian-chat-bridge.hilariobrehmer242.workers.dev |
| 私人 MCP 地址 | https://yejian-chat-bridge.hilariobrehmer242.workers.dev/mcp |
| GitHub OAuth 主页 | 服务根地址 |
| GitHub OAuth 回调 | https://yejian-chat-bridge.hilariobrehmer242.workers.dev/github/callback |
| 唯一允许的 GitHub 用户 | lunar0cean |
| GitHub OAuth App | 用户已注册「页间私人连接」，应用编号 3906041，并完成本人验证及密钥生成 |
| Workers Secrets | 用户明确允许保存后，GITHUB_CLIENT_ID 和 GITHUB_CLIENT_SECRET 已保存并部署；控制台均显示 Value encrypted |
| 初次代码部署版本 | 2ef3d1cb-c339-4955-95f6-8b277ce521ee；随后通过控制台部署上述 Secrets |
| D1 | yejian-chat，APAC；两项迁移均成功 |
| KV | OAUTH_KV，已绑定 |
| `/health` | 保存凭证后 HTTP 200，`modelAPI: false`、`configured: true` |
| OAuth 授权服务器及资源发现 | HTTP 200，地址均指向本服务 |
| 未授权 `/api/status` 和 `/mcp` | HTTP 401 |
| ChatGPT 网页账号 | 本人已登录，Plus 界面可见“工作”及“创建自定义 MCP 服务器”；不代表事件订阅已可用 |
| 私人 MCP 创建与授权 | 改用用户本人 Chrome 后创建成功，OAuth 自动发现及 GitHub 身份授权成功，ChatGPT“已安装”中已出现“页间私人连接” |
| 私人插件 ID | plugin_asdk_app_6ac3926f076081919271f77afbf0af1e |
| 工具与事件发现 | 插件详情显示 get_context、read_excerpts、publish_reply、create_note_draft 及 message.created |
| 网页 Work 普通工具调用 | 诊断请求 chrome-probe-20261005 调用 get_context，返回“找不到该请求。”；该 ID 故意不存在，不是实际用户消息 |
| 网页 Work 事件监控 | 系统事件发现找到 message.created 及两个过滤参数；实际创建监控返回 task service unexpected error，复核未保存监控，订阅未建立 |

`configured: true` 仅确认服务读到了部署配置和 GitHub 凭证。Chrome 的正式插件 OAuth 登录已成功；App 授权、刷新、撤销以及 ChatGPT 回传尚未验收，不能算作消息闭环成功。凭证未写入 Git、聊天或截图，传输用的临时文件已删除。

本次 CLI 保存遇到 Cloudflare 认证服务器网络错误，已改用本人登录的控制台完成保存；Wrangler 登录状态需在后续 CLI 部署前恢复。控制台与公网健康检查均已确认保存成功。

## ChatGPT 网页诊断

同一网页中，两次自动获取 OAuth 设置均失败。直接检查服务的授权服务器和资源发现接口均为 HTTP 200；未授权 `/mcp` 返回 HTTP 401，并携带正确的 `WWW-Authenticate` 资源发现地址。根据这份公开元数据手动填写 `/authorize`、`/token`、`/register`，选择 DCR 和 `bridge:read`、`bridge:write`、`offline_access` 后，创建仍被 ChatGPT 拒绝。

随后进入“账户安全与登录”，内嵌浏览器提示“无法加载安全设置”。未关闭 CSP、改动安全设置或购买套餐。

用户在 Chrome 打开同一账号后，已实际读取到正常的安全设置。Chrome 的私人 MCP 表单成功自动发现服务端点、权限及 CIMD 客户端 `https://chatgpt.com/oauth/client.json`，随后成功创建“页间私人连接”。本人确认的 `offline_access`、`bridge:read`、`bridge:write` 授权经 GitHub `read:user` 身份核对后成功回跳；ChatGPT“已安装”中已出现插件。原内嵌浏览器阻断已解除。

随后在网页创建 Work 测试对话「连接测试结果」。`get_context` 的空请求诊断得到服务返回，确认普通工具通路。Work 首次回答只根据普通工具列表误判没有事件入口；补充官方协议说明后，系统发现实际列出了 `message.created`，并尝试建立 `session_id=room-default`、`character_id=room-companion` 的纯事件监控。创建阶段返回 `The task service returned an unexpected error. Do not claim success.`，后续复核未保存监控。没有建立订阅、发布回复或创建时间计划。

这是实际创建失败，不能表述为账号不支持事件，也不能把插件目录发现当成订阅成功。[官方机制](https://developers.openai.com/plugins/build/mcp-events) 区分事件发现、订阅、回调验证与实际投递。网页没有给出服务端订阅错误详情，目前无法确定根因。当前实现另要求先经 App 创建对应角色会话；10 月 6 日 Sideloadly 已完成免费签名安装，用户确认 iPad 已进入阅读界面，App 授权与角色会话创建尚待完成。需在完成该前置条件后结合服务端诊断复测，不能将它直接认定为此次错误原因。

## 下一步

1. 使用已安装的私人连接，不重复创建同名插件。
2. 在已安装的 iPad App 填写服务根地址并完成 GitHub 授权，创建 room-default / room-companion 会话。
3. 在已有 Work 对话复测事件订阅；保存服务端请求及回调诊断，定位创建失败。成功创建并验证回调前，不声称自动连接可用。
4. 验证 App 授权刷新、撤销及恢复，进行十轮真实回传，填写 [验收表](../ipad-reader/docs/CHAT_ACCEPTANCE.zh-CN.md)。

完整 room 场景、语音、OCR 和 Gemini 接入继续按原门槛推进。
