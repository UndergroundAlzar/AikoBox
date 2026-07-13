# Unreleased (beta.1+)

## 工程笔记 (Engineering Notes)

> 以下为 beta.1 之后的工程进展记录，**不构成稳定版发布声明**。

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
