# 0.1.0

## 初始版本 (Initial Release)

- AikoBox 首个版本，fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)（GPL-3.0）
- 内核切换为 sing-box（唯一内核），订阅/覆写仍使用 Clash YAML 格式，启动时自动转换
- 品牌重塑：应用名 AikoBox，包名 `aikobox`，appId `com.aikobox.app`
- 保留 `clash://` `mihomo://` URL scheme，新增 `aikobox://`
- 停用应用内自动更新与内核更新，内核随应用发布
