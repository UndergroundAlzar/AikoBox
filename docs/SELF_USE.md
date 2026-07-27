# AikoBox 自用安全上手

这份清单面向第一次试用 AikoBox 的用户。目标不是最快切换，而是即使配置错误、程序退出或网络变化，也保留恢复联网的方法。

> AikoBox 仍是 Beta。第一次使用前保留现有代理/VPN、订阅原文和可用配置，不要先卸载设备上唯一能联网的软件。

## Windows：订阅链接

1. 从 [GitHub Releases](https://github.com/UndergroundAlzar/AikoBox/releases) 下载 Windows x64 安装版或便携版。
2. 使用同一 Release 中的 `.sha256` 校验文件；当前 Windows Beta 没有受信任代码签名，可能出现 SmartScreen。
3. 保持原代理可随时恢复，但避免两个软件同时占用相同端口。
4. 打开 AikoBox → 配置 → 导入 HTTPS 订阅链接。
5. 等待节点出现。更新失败时先检查超时、认证、无效内容或不安全跳转，不要忽略错误继续切换。
6. 选择节点并先启用普通系统代理。第一次不要启用 TUN。
7. 验证浏览器和常用应用联网正常。
8. 退出 AikoBox，确认 Windows 系统代理已恢复并且仍能联网。
9. 安装版确认上述流程稳定后，再测试需要管理员授权的 TUN；便携版不支持 TUN。

订阅更新失败时，AikoBox 会尽量保留此前可用配置。订阅已经失效、格式无法安全转换或候选配置未通过 sing-box 校验时，不应强制替换现有配置。

## Android：原生 sing-box JSON

1. 确认设备为 ARM64、Android 7.0 或更高。
2. 从 GitHub Release 下载 `arm64-v8a.apk`，核对 APK 的 `.sha256`。
3. 安装时确认来源为本仓库。项目固定发布证书 SHA-256 为：
   `8896E81ED78BAACCD385DB95D4591FAA8EC7EF5A87D488258DBA53DA65276B94`
4. 从本地文件、HTTPS 地址或粘贴内容导入**原生 sing-box JSON**。
5. 先执行配置校验，再授予 Android VPN 权限。
6. Android 13 及以上同时授予通知权限，确保常驻通知和“停止”操作可用。
7. 连接后分别测试 Wi-Fi、移动网络切换、锁屏恢复和主动停止。

当前 Android Release 不支持 Clash YAML、订阅 URI、节点测速、应用分流或自动更新订阅。仓库 `mobile/` 中的实验功能不代表公开 APK 已支持。

## 不要这样做

- 不要在确认退出恢复前，把 AikoBox 作为设备唯一联网路径。
- 不要在公开 Issue、截图、聊天或日志中粘贴完整订阅 URL。
- 不要上传含节点地址、UUID、密码、令牌、控制器密钥或个人路径的配置。
- 不要为了复现问题关闭杀毒软件、防火墙或 Android 系统安全保护。
- 不要从第三方网盘、群文件或重新打包站点安装 AikoBox。

## 出现问题时

先切回原代理或停止 Android VPN，再记录：

- AikoBox 版本与下载文件名
- Windows/Android 版本及设备架构
- 使用的模式（系统代理、TUN 或 Android VPN）
- 已脱敏的错误信息和最小重现步骤

普通问题可使用 [Issue 模板](https://github.com/UndergroundAlzar/AikoBox/issues/new/choose)；安全问题按 [SECURITY.md](../SECURITY.md) 私密报告。
