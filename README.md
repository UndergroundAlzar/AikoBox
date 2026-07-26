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

AikoBox 是一款以 sing-box 为唯一内核的客户端：桌面端面向 **Windows x64**，界面与订阅工作流源自 Clash Party；移动端为 **Android arm64-v8a**，界面参照 FlClash。Aiko 是项目的白毛红瞳看板娘。

> 项目仍处于 `0.x` Beta 阶段。预发行版必须通过第三方许可审计和静态产物校验；若尚未配置受信任的 Windows 代码签名证书，Release 会明确标注“未签名 Beta”。在系统代理或 TUN 成为唯一联网路径前，请先保留可恢复的网络方案。

## 自用快速上手（只会订阅链接）

若你主要使用订阅 URL，请先阅读 [docs/SELF_USE.md](./docs/SELF_USE.md)：

1. **先保留现有代理**，不要立刻卸载唯一可用的 VPN/代理
2. 导入订阅链接 → 等待节点出现
3. 打开**普通系统代理**（先不要开 TUN）→ 选择节点
4. 退出软件后确认系统仍能上网

## 特性

- 订阅和覆写保持 Clash YAML 使用方式，启动内核前转换为 sing-box JSON
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
node scripts/prepare.mjs --x64
pnpm run review
pnpm test
pnpm run build:win
```

`pnpm test` 包含使用随项目资源准备的 sing-box 执行 `check` 的配置校验，但不会启动代理服务。`pnpm run build:win` 生成安装包、便携版和 SHA-256 文件到 `dist/`。

开发时运行 `pnpm dev` 会实际启动桌面应用和内核。若电脑已经依赖其他代理联网，请先使用独立的高位测试端口，并确保系统代理和 TUN 默认关闭。

## Android 客户端

源码在 [`mobile/`](./mobile)，Flutter 3.44 + sing-box `libbox`，**仅 arm64-v8a**（不提供 armeabi-v7a 或 x86）。界面语言参照 [FlClash](https://github.com/chen08209/FlClash) 的 Material You 设计。

桌面端不可协商的那几条约束在这里逐条保留：内核证明健康之前不放行流量、旧内核仍在服务时先校验候选配置、保留 last-known-good 并在候选被拒时自动回滚、无法安全转换时拒绝静默降级为直连。Windows 特有的机制（WinINET 系统代理、UAC 提权、托盘）不适用，取而代之的是 `VpnService`——在 Android 上 VPN 同时承担了系统代理和 TUN 两个角色。

内核不随应用更新：`libbox.aar` 由 [`.github/workflows/android-libbox.yml`](./.github/workflows/android-libbox.yml) 从 `SagerNet/sing-box v1.13.14` 源码构建，锁定在 [`scripts/resources-lock.android.json`](./scripts/resources-lock.android.json)，并在 Gradle 链接之前由 `scripts/verify-android-core.mjs` 校验。SagerNet 不发布预编译 AAR；社区存在第三方镜像，但本项目**不采用**——那是无关联账号发布的不可复现二进制，会运行在 VPN 进程内、能看到全部流量。

本地构建需要 Flutter 3.44.8、Android SDK 36、NDK r28 与 JDK 17：

```powershell
# 先产出内核绑定（需要 Go 1.25+ 与 SagerNet 的 gomobile 分支）
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
go run ./cmd/internal/build_libbox -target android -platform android/arm64   # 在 sing-box 仓库内
copy libbox.aar <AikoBox>\mobile\android\app\libs\libbox.aar

cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

转换器与订阅解析是纯 Dart 包，单独测试：

```powershell
cd mobile\packages\aikobox_convert;      dart test
cd mobile\packages\aikobox_subscription; dart test
```

`aikobox_convert` 的测试会用真实的 sing-box 二进制对转换结果执行 `check`，并与 TypeScript 实现的逐字节黄金基准对照，两边不会各自漂移。

## 安全与许可

安全问题请遵循 [SECURITY.md](./SECURITY.md)，第三方组件见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。

本项目 fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)，感谢其贡献者。AikoBox 依据 [GPL-3.0](./LICENSE) 许可证开源。
