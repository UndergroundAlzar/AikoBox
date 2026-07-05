# AikoBox

基于 **sing-box** 内核的代理客户端，界面源自 Clash Party。

- 订阅、覆写、Sub-Store 等仍使用 Clash YAML 生态，启动时自动转换为 sing-box 配置运行
- 保留 `clash://` 与 `mihomo://` 一键导入协议，并新增 `aikobox://`
- 支持 Windows / macOS / Linux

## 构建

```bash
pnpm install
pnpm dev        # 开发调试
pnpm build:win  # 构建 Windows 安装包
```

## 致谢与许可

本项目 fork 自 [Clash Party](https://github.com/mihomo-party-org/clash-party)（mihomo-party-org/clash-party），感谢上游项目的工作。

依据 [GPL-3.0](./LICENSE) 许可证开源。

---

## English

AikoBox is a proxy client powered by the **sing-box** core, with a UI derived from Clash Party. Subscriptions and overrides stay in the Clash YAML ecosystem and are converted to sing-box configuration at launch. The `clash://` and `mihomo://` import schemes are kept, and `aikobox://` is added.

Build: `pnpm install`, then `pnpm dev` for development or `pnpm build:win` for a Windows installer.

Forked from [Clash Party](https://github.com/mihomo-party-org/clash-party) (mihomo-party-org/clash-party). Licensed under [GPL-3.0](./LICENSE).
