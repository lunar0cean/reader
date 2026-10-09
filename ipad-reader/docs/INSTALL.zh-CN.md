# 页间：Windows 免费签名与首次连接

V0.7 更新包目录为 `D:\ios\builds\YeJian-v0.7`：`YeJian-with-voices.ipa` 附带现有模型和角色，支持直接离线朗读及录音添加角色；`YeJian-unsigned.ipa` 为不含模型的较小包，可在 App 中导入模型。先分别导出书库 JSON 与笔记本 JSON，再用原 Apple ID、同一 Sideloadly 配置覆盖安装，保留旧 App。两种 IPA 均需签名，应用标识保持 `com.lunar0cean.yejian`。

安装后：书页长按文字可以选择和复制，单点插图进入可缩放、复制的图片页；顶部扬声器准备当前页朗读。书库右上「管理朗读角色」可选角色、导入 `.gsvpack` 和「用录音添加角色」。离线合成和创建角色的实际速度需在本人 A16 上确认，参见 [朗读模块说明](../Voice/INTEGRATION.md)。ChatGPT 连接仍保持原设置和暂停排查状态。

2026 年 10 月 6 日首次安装记录：Sideloadly 0.70.1 已识别 USB 连接的 iPad，设备列表显示系统版本 26.7；本人完成 Apple 账号认证后显示 `Done.`，免费签名安装完成。本人确认 V0.4 已打开阅读界面并连接 GitHub，App 状态为「待订阅」；其他功能及真机兼容性继续实测。ChatGPT 的「页间私人连接」已经创建并授权，实际事件订阅尚未完成，连接排查暂时暂停。

旧 V0.4 首次交付目录：`D:\ios\builds\YeJian-chat-bridge`。原安装文件的 SHA-256 为 `9bf9e57ed061d221a7838fc1509697b49fe71766826b4d306cde249ce206d755`。V0.6 已检查包内版本 0.6.0、最低系统 17.0、应用标识 `com.lunar0cean.yejian`、包含 iPad 设备类型及 IPA 内容 CRC。GitHub 构建压缩包 SHA-256 与服务提供的摘要一致。这不代替实际系统兼容性验证。

1. 使用支持数据传输的 USB 线连接 iPad 与 Windows，解锁 iPad。按设备提示由本人信任这台电脑；iTunes 中应能看到 iPad。当前电脑已检测到 iTunes 12.13.7.1、Apple Mobile Device Support 18.5.0.13，以及正在运行的设备和 Bonjour 服务；Windows 已识别 Apple iPad 与 Apple USB 设备，状态正常。USB 识别不代表已经完成设备信任或免费签名。[Apple 设备配对说明](https://support.apple.com/en-ie/109054)
2. 从 [Sideloadly 官网](https://sideloadly.io/index.html) 安装 Windows 64 位工具。本次下载放在交付目录的 `setup\SideloadlySetup64.exe`。安装条款、Apple 账号、密码和验证码由本人在工具中处理。官方要求 Windows 使用网页版 iTunes / iCloud；遇到依赖提示时按官网提供的 Apple 下载入口处理，现有软件不自动卸载。
3. 在 Sideloadly 选择 iPad，将 `YeJian-unsigned.ipa` 拖进去，使用本人免费 Apple 账号签名安装。保留普通 Apple ID 安装方式，不添加修改插件。若提示「未受信任的开发者」，在 iPad「设置 → 通用 → VPN 与设备管理」选择本次签名账号并确认。[Sideloadly 安装与信任说明](https://sideloadly.io/faq.html)
4. 如果设备要求开发者模式，在 iPad「设置 → 隐私与安全性 → 开发者模式」按提示开启、重启并由本人确认。未显示入口时，先完成配对和一次安装尝试，记录实际提示；不据此更改 ChatGPT 的安全设置。[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
5. V0.7 默认进入统一书库，笔记本从独立封面打开，Markdown 和基础 PPTX 文件从「导入」添加。书库右上可管理离线朗读角色。连接设置沿用既有值，排查继续暂停；如需查看，可从书库右上连接图标或阅读器「更多 → 连接 ChatGPT → 服务与角色设置」进入。以下连接步骤保留为原有安装记录和后续路线。

| 设置 | 值 |
| --- | --- |
| 服务根地址 | `https://yejian-chat-bridge.hilariobrehmer242.workers.dev` |
| 会话 ID | `room-default` |
| 角色 ID | `room-companion` |
| 角色名 | `书房伙伴` |
| 角色对话网址 | 同一账号中的 Work 对话「连接测试结果」 |

6. 点「使用 GitHub 授权」，使用 `lunar0cean` 登录。成功回到 App 后会创建上述角色会话；ChatGPT 的插件授权与 App 的授权是两个客户端。本人反馈已完成 App 登录；服务只请求 `read:user` 核对本人身份。以下第 7–8 步保留为后续连接验证路线，本轮暂停执行。
7. 在 iPad Safari 打开同一 ChatGPT 账号中的已有 Work 对话，使用已安装的「页间私人连接」，不要重新创建。将 App 的「复制 Work 设置提示词」粘贴到对话，要求用系统事件监控入口订阅 `message.created`，按上述会话和角色过滤，逐条处理，无时间计划。必须确认订阅保存且回调验证成功；目录里显示事件不表示订阅已建立。[OpenAI 官方事件机制](https://developers.openai.com/plugins/build/mcp-events)
8. 回 App 点「检查连接」。状态为「可用」后，先发送一条文字；收到回传后再运行「十轮真实验证」。首次测试不要勾选共享书页。收起聊天网页、保持 App 前台，验证自动回应，最后导出连接诊断并填写 [实测表](CHAT_ACCEPTANCE.zh-CN.md)。若仍报监控创建错误，先核对云端订阅请求和回调原因，不将失败写成通过。

费用按免费路线：Sideloadly 可使用免费 Apple 账号，签名通常有效七天；续签继续使用相同账号与安装配置覆盖现有 App，提前导出可编辑备份。自动续签需要电脑与设备通过 USB 或已配对的同一局域网连接，电脑关机时不能替设备续签。首次 Wi-Fi 配对需要 USB。Cloudflare 当前保持免费套餐；ChatGPT 使用现有账号权益，不启用付费模型 API。[Sideloadly 续签说明](https://sideloadly.io/faq.html)

安装时记录 iPad「设置 → 通用 → 关于本机」中的型号与系统版本。Sideloadly 已从 USB 连接的设备显示版本 26.7，但「关于本机」中的具体型号与版本仍待本人复核；读取到系统版本不代表 App 已通过兼容性验收。完整 room3d 在真实十轮闭环通过后再接入。
