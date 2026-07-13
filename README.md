<p align="center">
  <img src="./build/aiko-mascot.png" width="180" alt="AikoBox mascot Aiko" />
</p>

<h1 align="center">AikoBox</h1>

<p align="center">
  专为 Windows 打造的 sing-box 图形客户端：兼容 Clash YAML 订阅，重视安全更新、故障回滚与不断网保护。
</p>

<p align="center">
  中文 · <a href="./README_EN.md">English</a>
</p>

AikoBox 是一款仅面向 **Windows x64** 的 sing-box 桌面客户端，界面与订阅工作流源自 Clash Party。Aiko 是项目的白毛红瞳看板娘。

> 项目仍处于 `0.x` Beta 阶段。预发行版必须通过第三方许可审计和静态产物校验；若尚未配置受信任的 Windows 代码签名证书，Release 会明确标注“未签名 Beta”。在系统代理或 TUN 成为唯一联网路径前，请先保留可恢复的网络方案。

## 特性

- 订阅、覆写和 Sub-Store 保持 Clash YAML 使用方式，启动内核前转换为 sing-box JSON
- sing-box 是唯一代理内核，并通过 Clash API 兼容层向界面提供运行状态
- 支持普通节点、`proxy-providers` 和 `rule-providers`；无法安全转换的关键配置会拒绝生效
- 保留 `clash://`、`mihomo://` 导入协议，并提供 `aikobox://`
- 可由用户手动检查 sing-box 稳定版更新；下载后验证官方 SHA-256、版本、平台和候选配置，启动失败自动回滚
- 提供安装到 Program Files 的按机器安装包和单文件便携版；不提供 macOS、Linux、ARM64 或 32 位版本
- 不静默安装应用或内核更新；所有内核切换都需要用户确认

## 系统要求

- Windows 10 或 Windows 11，x64
- 普通系统代理模式不要求管理员权限
- TUN 模式仅在安装包版本中可用，需要 Windows 管理员授权；拒绝授权不会影响当前正在运行的连接
- 便携版和开发版只支持普通系统代理模式，不会请求 TUN 提权

## 下载与校验

每个版本提供以下文件：

- `aikobox-windows-<version>-x64-setup.exe`：按机器安装到 Program Files，安装时需要管理员授权，支持 TUN
- `aikobox-windows-<version>-x64-portable.exe`：单文件便携版，配置和日志保存在便携目录，仅支持普通系统代理模式
- 与每个 `.exe` 同名的 `.sha256`：该可执行文件的 SHA-256 校验值

请只从本项目的 GitHub Releases 下载。可在 PowerShell 中核对单个文件：

```powershell
$actual = (Get-FileHash .\aikobox-windows-0.1.0-beta.1-x64-setup.exe -Algorithm SHA256).Hash.ToLower()
$expected = ((Get-Content .\aikobox-windows-0.1.0-beta.1-x64-setup.exe.sha256) -split '\s+')[0]
$actual -ceq $expected
```

结果必须为 `True`。正式版本会拒绝未签名产物；预发行版在证书尚未配置时允许发布，但发布页必须明确标注“未签名 Beta”，且工作流会确认产物确实未签名。Windows 显示未知发布者或 SmartScreen 提示时，不要绕过来源和校验检查。

## 配置说明

用户编辑的是 Clash YAML，实际运行的是生成后的 sing-box 配置。两者并非逐字段等价；AikoBox 会转换常见代理协议、代理组、DNS、规则和 provider。对于会改变路由语义且无法可靠转换的配置，应用应保留当前可用内核并报告错误，而不是退回直连。

订阅 URL、认证信息、控制器密钥和完整日志都可能包含敏感信息。提交问题前请先脱敏，详见 [SECURITY.md](./SECURITY.md)。

## 本地构建

要求 Windows x64、Node.js 22 或更高版本，以及项目声明的 pnpm 版本：

```powershell
corepack enable
pnpm install --frozen-lockfile
pnpm run review
pnpm test
pnpm run build:win
```

`pnpm test` 包含使用随项目资源准备的 sing-box 执行 `check` 的配置校验，但不会启动代理服务。`pnpm run build:win` 生成安装包、便携版和 SHA-256 文件到 `dist/`。

开发时运行 `pnpm dev` 会实际启动桌面应用和内核。若电脑已经依赖其他代理联网，请先使用独立的高位测试端口，并确保系统代理和 TUN 默认关闭。

## 安全与许可

安全问题请遵循 [SECURITY.md](./SECURITY.md)，第三方组件见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。

本项目 fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)，感谢其贡献者。AikoBox 依据 [GPL-3.0](./LICENSE) 许可证开源。
