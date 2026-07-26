# Unreleased (beta.1+)

## Android 客户端 (Android client)

> 新增 `mobile/`，Flutter + sing-box `libbox`，**仅 arm64-v8a**。尚未发布任何 APK。

- 界面参照 [FlClash](https://github.com/chen08209/FlClash) 的 Material You 设计语言：底部四页导航、仪表盘卡片网格、Surfboard 风格节点网格、动态取色
- 内核为 sing-box v1.13.14 的 gomobile 绑定，从 `SagerNet/sing-box` 源码构建；SagerNet 不提供预编译 AAR，第三方镜像因无法核实来源而**不予采用**
- `packages/aikobox_convert`：Clash YAML → sing-box JSON 转换器的纯 Dart 移植，与 TypeScript 实现共用一套逐字节对照的黄金基准，并用真实 sing-box 二进制校验输出
- `packages/aikobox_subscription`：订阅载荷归一化与分享链接解析的纯 Dart 移植，沿用桌面端的全部边界与脱敏规则
- VpnService 运行在 `:remote` 进程；支持 always-on VPN、开机恢复、快捷设置磁贴、分应用代理
- 桌面端的不可协商约束在安卓端逐条保留：内核健康前不放行流量、旧内核仍在服务时校验候选配置、保留 last-known-good 并自动回滚、拒绝静默降级为直连

## 工程笔记 (Engineering Notes)

> 以下为 beta.1 之后的工程进展记录，**不构成稳定版发布声明**。

- 安全修复 (Security fixes)：修复 `getIconDataURL` 的命令注入（内核上报的进程路径被拼进 `cmd.exe`，配合 TUN 自提权可升至管理员）、备份还原的路径穿越、计划任务 XML 的 TOCTOU、渲染进程可驱动的任意 URL 请求，以及 clash_api secret 外泄给第三方面板
- 稳定性 (Stability)：补上全局 `unhandledRejection` 处理器，修正 `/traffic` 流中位于 try 之外的 `JSON.parse`（单个畸形帧即可终止主进程），并阻止内核守护在关闭过程中重新拉起进程导致 sing-box 成为孤儿进程
- 转换器 (Converter)：检出与代理节点同名的代理组（此前会产生重复 outbound tag 而被内核拒绝）、解析而非丢弃 `no-resolve`、跳过会匹配全部域名目标的反向 IP 规则
- 本地化 (i18n)：补齐 33 个在所有语言文件中均不存在的 key（整个插件界面此前显示原始 key），并新增 `scripts/audit-i18n.mjs` 纳入 review 与 CI
- 许可证证据推进 (License evidence advances)：补强开源合规与许可证归属材料
- CI 隔离基础 (CI isolation foundations)：为后续独立流水线与发布隔离打底
- 工厂测试 (Factory tests)：补充可重复的构建/装配侧验证
- UX 诚实性 (UX honesty)：界面与文案对齐真实能力边界，避免过度承诺

# 0.1.0-beta.1

## 初始版本 (Initial Release)

- AikoBox 首个 Beta 版本（`0.1.0-beta.1`），fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)（GPL-3.0）
- 内核切换为 sing-box（唯一内核），订阅/覆写仍使用 Clash YAML 格式，启动时自动转换
- 品牌重塑：应用名 AikoBox，包名 `aikobox`，appId `com.aikobox.app`
- 保留 `clash://` `mihomo://` URL scheme，新增 `aikobox://`
- 应用更新不静默安装；新增用户确认的 sing-box 安全更新、官方摘要校验、候选检查和失败回滚
- 加固订阅/Provider 下载、深链确认、系统代理恢复和进程归属
- 仅发布 Windows x64，提供安装到 Program Files 的按机器安装包与单文件便携版
- 发布产物附带 SHA-256 校验清单，不再生成 macOS 或 Linux 包
