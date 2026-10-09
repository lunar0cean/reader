# 阅读器 · 原生 iPad App

供自己使用的阅读器：舒服地读书，直接在书页上手写，向 AI 提问并回到引用的原文。

本仓库用于公开免费编译，迁移范围见 [迁移说明](PUBLIC_MIGRATION.md)。

当前项目代码位于 [`ipad-reader/`](ipad-reader/README.md)。旧每日英语系统、邮件发送、词表、历史记录与定时工作流已经从这一版本移除，本公开仓库使用全新的 Git 历史。

## 现在查看阅读 UI

启动本地服务器查看预览：

```powershell
cd D:\ios\reader-public\ipad-reader\Preview
python -m http.server 8877 --bind 127.0.0.1
```

浏览器访问 <http://127.0.0.1:8877>。

本版包含书库、阅读设置、TXT／EPUB／PDF／HTML 导入、公开网页离线保存、独立批注、文字笔记、引用跳转、导出和恢复。原生 V0.5 增加滑动翻页与侧栏、双指整页缩放、顶部笔工具和 RGB／笔宽滑杆，默认 Pencil 写画、手指导航，见 [阅读手势说明与测试](ipad-reader/docs/READING_FEEL.zh-CN.md)。SwiftUI 与 PencilKit 工程由 GitHub macOS 工作流编译未签名 IPA；本人已完成免费签名安装并打开 V0.4，V0.5 更新后仍需复核真机手感。

ChatGPT 私人插件服务已部署到 Cloudflare 免费账号，Chrome 插件授权完成；本人反馈 App 已连接 GitHub，状态为「待订阅」。事件连接排查暂时暂停，真实消息闭环尚未验收，详见 [连接实测记录](ipad-reader/docs/CHAT_ACCEPTANCE.zh-CN.md)。原有 AI 摘录面板继续作为本地示例。

- [本版功能和运行说明](ipad-reader/README.md)
- [阅读器开发规划](ipad-reader/docs/PLAN.zh-CN.md)
- [Claude 场景与原生程序的协作接口](ipad-reader/docs/SCENE_BRIDGE.zh-CN.md)
- [ChatGPT 插件部署与首次连接](chat-bridge/README.md)
- [Windows 免费签名与 iPad 首次安装](ipad-reader/docs/INSTALL.zh-CN.md)
- [真实十轮与 A16 iPad 验收表](ipad-reader/docs/CHAT_ACCEPTANCE.zh-CN.md)

Claude 负责 3D 场景与分镜，Codex 负责原生程序和连接。3D 书房以后接入，当前阅读流程独立运行。`D:\ios\room3d` 中的已有场景没有被改动。
