# 与 Claude 的 3D 协作约定（预留，尚未接入）

Claude 管场景和分镜，Codex 管程序与原生阅读器连接。当前 `D:\ios\room3d` 文件保持原样，不作为阅读器启动资源。

## 交付边界

场景交付包含入口 HTML、全部模型与动作 JSON、纹理和固定版本的本地 JS 依赖。禁止依赖在线 CDN 才能启动。后续用 `WKURLSchemeHandler` 提供 `yejian://scene/room.html` 同源资源；页面资源路径用相对路径。路径需规范化后限制在打包资源根目录内。

阅读器从书库、进度和用户操作生成状态；场景只通过白名单消息请求动作，不直接访问原文、AI 密钥和笔记文件。

## 原生发送给场景

```json
{
  "version": 1,
  "type": "readerState",
  "payload": {
    "books": [{"id": "book-id", "title": "书名", "progress": 0.25}],
    "activeBookId": "book-id",
    "isVisible": true,
    "reduceMotion": false
  }
}
```

页面实现 `window.YeJianScene.receive(message)`。`isVisible=false` 时暂停 requestAnimationFrame、动作、音频和物理更新；再次显示时恢复。角色动画另发 `characterAction`，使用稳定动作名称，不依赖镜头内部编号。

## 场景发送给原生

```javascript
window.webkit?.messageHandlers.readerBridge.postMessage({
  version: 1,
  type: "openBook",
  payload: { bookId: "book-id" }
});
```

初期允许 `sceneReady`、`openBook`、`closeScene`、`sceneError`。原生检查版本、消息大小和书籍 ID 是否存在。AI、笔记写入与外部链接不自动开放。

普通浏览器预览没有 `window.webkit` 时，页面可打印调试事件并维持独立场景体验。读书房间不触发网页原生导航来代替消息接口。

## 场景验收

离线启动无白屏；反复进出书房不会重复初始化消息处理器；场景隐藏后停止渲染；点击书籍能打开对应原生阅读位置；场景错误时仍能进入书库和阅读。
