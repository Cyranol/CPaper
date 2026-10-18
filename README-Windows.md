# Codex 启动动画 · Windows 版

这是针对当前电脑 Microsoft Store 版 Codex/ChatGPT 的 Windows 外部启动器。它沿用原项目的 12 秒动画、自定义头像/背景/文字和动画后的静态壁纸，不修改 Microsoft Store 安装包，也不替换 Codex 的聊天、模型或工具功能。

## 兼容性

- Windows 11 x64
- Microsoft Store 包：`OpenAI.Codex`
- 已在 Windows 11 x64 构建 26200、Codex `26.1007.2314.0` 上验证
- 启动时会自动发现更新后的包目录，不写死版本路径
- 直接复用官方应用随附的 Node.js，不需要安装 npm 依赖

## 使用

1. 保存工作并完全退出正在运行的 Codex/ChatGPT 桌面应用；托盘中仍在运行也要退出。
2. 双击 `启动 Codex 动画.cmd`。
3. 动画结束后会进入正常 Codex 页面。按 `Ctrl+Alt+B` 可再次打开图片、文字和背景设置。

如果不想每次打开 `.cmd`，双击一次 `安装 ChatGPT 图标.cmd`。它会在桌面创建两个使用官方图标的快捷方式：`ChatGPT` 始终通过 Windows 官方入口启动，`ChatGPT 动画` 才进入动画启动流程。启动器文件会安装到当前用户的 `%APPDATA%\CodexStartupAnimation`，移动或删除源码文件夹不会影响桌面图标。

Microsoft Store 自带的开始菜单、任务栏图标和新建的桌面 `ChatGPT` 图标都直接启动官方应用。动画入口保持独立，避免动画接入失败时影响正常启动；如需把动画入口固定到任务栏，请固定桌面的 `ChatGPT 动画`。

如果 Codex 是从 `ChatGPT 动画` 启动并仍在后台运行，再次点击该图标会重新连接新窗口并应用动画与背景。如果当前实例从官方入口启动，动画入口只会正常唤醒窗口并跳过本次动画，不再弹出错误，也不会强制结束正在运行的任务。

双击 `预览动画.cmd` 可以在浏览器中预览，不会启动或修改 Codex。双击 `检查兼容性.cmd` 可以重新检查安装位置、版本、签名和运行时。

## 安全与恢复

- 启动前验证应用包标识、产品名和 OpenAI Authenticode 数字签名。
- 调试端口使用随机端口并严格绑定 `127.0.0.1`；连接前还会核对监听进程路径和 Windows 会话。
- 启动器不修改 `WindowsApps`、`app.asar`、账户或 API 配置。
- 若接入失败，完全退出应用，再从官方图标正常打开即可恢复；这也会结束本次调试端口。

Microsoft Store 更新可能改变窗口结构。若更新后动画不再出现，先运行兼容性检查，再按终端中的错误信息重新适配。

开发时可用本机 Edge 做完整浏览器冒烟测试：

```powershell
node tools/browser-smoke-windows.mjs --browser "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
```
