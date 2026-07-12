# 0.1.0

## 初始版本 (Initial Release)

- AikoBox 首个版本，fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)（GPL-3.0）
- 内核切换为 sing-box（唯一内核），订阅/覆写仍使用 Clash YAML 格式，启动时自动转换
- 品牌重塑：应用名 AikoBox，包名 `aikobox`，appId `com.aikobox.app`
- 保留 `clash://` `mihomo://` URL scheme，新增 `aikobox://`
- 应用更新不静默安装；新增用户确认的 sing-box 安全更新、官方摘要校验、候选检查和失败回滚
- 加固订阅/Provider 下载、Sub-Store 本地接口、深链确认、系统代理恢复和进程归属
- 仅发布 Windows x64，提供安装到 Program Files 的按机器安装包与单文件便携版
- 发布产物附带 SHA-256 校验清单，不再生成 macOS 或 Linux 包
