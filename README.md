<p align="center">
  <img src="./build/aiko-mascot.png" width="180" alt="AikoBox 看板娘 Aiko" />
</p>

<h1 align="center">AikoBox</h1>

<p align="center">
  Windows x64 与 Android ARM64 的 sing-box 图形客户端
</p>

<p align="center">
  <a href="https://github.com/UndergroundAlzar/AikoBox/actions/workflows/quality.yml"><img src="https://github.com/UndergroundAlzar/AikoBox/actions/workflows/quality.yml/badge.svg?branch=main" alt="质量门禁" /></a>
  <a href="https://github.com/UndergroundAlzar/AikoBox/releases"><img src="https://img.shields.io/github/v/release/UndergroundAlzar/AikoBox?include_prereleases&label=release" alt="最新版本" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/UndergroundAlzar/AikoBox" alt="GPL-3.0-only" /></a>
</p>

<p align="center">
  中文 · <a href="./README_EN.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/UndergroundAlzar/AikoBox/releases">下载 AikoBox</a>
  ·
  <a href="./docs/SELF_USE.md">自用快速上手</a>
  ·
  <a href="https://github.com/UndergroundAlzar/AikoBox/issues">问题反馈</a>
</p>

AikoBox 以 sing-box 为唯一代理内核。Windows 端兼容 Clash YAML 订阅，并重点保护系统代理恢复、候选配置校验与故障回滚；Android 端通过系统 `VpnService` 运行锁定版本的 `libbox`。

> [!WARNING]
> AikoBox 仍处于 `0.x` Beta。Windows 预发行包目前没有受信任的 Authenticode 签名，可能触发“未知发布者”或 SmartScreen；Android APK 使用项目固定发布证书签名。首次使用时请保留现有代理和配置备份，不要立即把 Beta 作为设备唯一的联网方案。

## 当前支持情况

| 能力                  | Windows x64  | Android arm64-v8a |
| --------------------- | ------------ | ----------------- |
| 原生 sing-box JSON    | 支持         | 支持              |
| Clash YAML 与订阅 URI | 支持         | 暂不支持          |
| 订阅管理与自动更新    | 支持         | 暂不支持          |
| 节点延迟测试          | 支持         | 暂不支持          |
| 普通系统代理          | 支持         | 不适用            |
| TUN / 系统 VPN        | 安装版支持   | 支持              |
| 应用分流              | 通过规则配置 | 暂不支持          |
| 安全更新与回滚        | 支持         | 配置校验后切换    |

Android 当前公开版专注于可靠运行原生 sing-box JSON。Clash YAML 转换、订阅管理、节点测速、应用分流和自动更新订阅在后续版本计划中；README 不把实验代码中的能力视为已发布功能。

## 下载

请只从 [GitHub Releases](https://github.com/UndergroundAlzar/AikoBox/releases) 下载。

### Windows

- `aikobox-windows-<version>-x64-setup.exe`：安装到 Program Files，支持系统代理和 TUN；安装及 TUN 需要管理员授权。
- `aikobox-windows-<version>-x64-portable.exe`：单文件便携版，仅支持普通系统代理。
- 两个文件目前均为明确标注的未签名 Beta。发布工作流会验证它们确实未签名，并附带 SHA-256。

### Android

- `aikobox-android-<version>-arm64-v8a.apk`：Android 7.0（API 24）或更高，仅支持 ARM64。
- APK 使用固定发布证书签名；证书 SHA-256：
  `8896E81ED78BAACCD385DB95D4591FAA8EC7EF5A87D488258DBA53DA65276B94`
- 不提供 Play 商店、armeabi-v7a、x86 或 x86_64 安装包。

每个二进制都有同名 `.sha256`，Release 还提供统一的 `SHA256SUMS.txt`、构建清单、第三方许可审计，以及核心组件的对应源码和许可证材料。

在 PowerShell 中校验下载文件：

```powershell
$file = '.\aikobox-windows-0.1.0-beta.3-x64-setup.exe'
$expected = ((Get-Content "$file.sha256") -split '\s+')[0]
$actual = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
$actual -ceq $expected
```

结果必须为 `True`。校验和只能证明文件与发布清单一致，不能替代可信下载来源和代码签名。

## 快速上手

### Windows：订阅链接

1. 保留当前可用的代理软件。
2. 导入订阅链接并等待节点出现。
3. 先选择节点并启用普通系统代理，不要第一次就启用 TUN。
4. 验证网页和常用应用正常联网。
5. 退出 AikoBox，确认 Windows 系统代理已恢复且仍可联网。

### Android：sing-box JSON

1. 从 Release 安装 ARM64 APK，并允许系统 VPN 和通知权限。
2. 从本地文件、HTTPS 地址或粘贴内容导入原生 sing-box JSON。
3. 先执行配置校验，再授予 VPN 权限并连接。
4. 测试 Wi-Fi、移动网络切换和停止连接。

完整的安全试用步骤见 [自用快速上手](./docs/SELF_USE.md)。

## 设计原则

- **失败关闭**：关键配置无法安全转换或校验失败时，拒绝切换，不静默退回直连。
- **保护现有连接**：候选配置先校验；系统代理恢复或核心停止失败时，不假装退出成功。
- **可验证供应链**：锁定 sing-box、libbox 和 sysproxy 来源、版本、哈希及许可证证据。
- **不静默安装**：应用和内核更新都需要用户明确操作。
- **最小化秘密暴露**：订阅 URL、认证信息、控制器密钥和日志按敏感信息处理。

## 系统要求与限制

### Windows

- Windows 10 或 Windows 11，x64。
- 普通系统代理不需要管理员权限。
- TUN 只在安装版可用，并需要管理员授权。
- 不支持 macOS、Linux、Windows on ARM 或 32 位 Windows。

### Android

- Android 7.0（API 24）或更高，arm64-v8a。
- 必须授予 VPN 权限；Android 13 及以上还需通知权限。
- 当前仅导入原生 sing-box JSON，不承诺 Clash YAML、订阅 URI、应用分流、快捷磁贴或开机自启。

## 源码结构

- `src/`：Windows Electron 客户端、Clash 订阅处理和 sing-box 转换。
- `apps/android/`：当前 Release 使用的精简 Android 客户端。
- `mobile/`：实验中的下一代 Android 客户端，包含更多 UI 和跨平台转换工作；**不属于当前公开 APK**。

两套 Android 代码的功能不能混为一谈。只有 `.github/workflows/release.yml` 构建并验证的 `apps/android/` 会进入当前 GitHub Release。

## 本地验证

Windows 开发要求 Node.js 22 和仓库声明的 pnpm 版本：

```powershell
corepack enable
pnpm install --frozen-lockfile
node scripts/prepare.mjs --x64
pnpm run review
pnpm test
pnpm run build:win
```

当前 Android 发布链锁定 Flutter 3.44.4、JDK 17、Go 1.24.7、Android SDK 36 和 NDK r28。完整的 libbox 构建、签名、ABI 与许可证验证以 [质量工作流](./.github/workflows/quality.yml) 和 [发布工作流](./.github/workflows/release.yml) 为准。

## 路线图

- Android Clash YAML 与订阅 URI 转换
- Android 订阅管理和手动刷新
- Android 节点延迟测试
- Android 应用分流
- Android 后台自动更新订阅
- Windows 受信任代码签名

路线图表示开发方向，不承诺具体发布日期。

## 安全、贡献与许可

- 安全问题请按 [SECURITY.md](./SECURITY.md) 私密报告，不要公开订阅、令牌或未脱敏日志。
- 开发和提交要求见 [CONTRIBUTING.md](./CONTRIBUTING.md)。
- 第三方组件、来源和许可证见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。

AikoBox fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)，感谢其贡献者。项目依据 [GPL-3.0-only](./LICENSE) 开源。
