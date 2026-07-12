# 参与贡献

感谢你愿意改进 AikoBox。项目目前是仅面向 Windows x64 的源码预览；开始前请先阅读 [README.md](./README.md)、[英文 README](./README_EN.md) 和 [SECURITY.md](./SECURITY.md)。

## 提交问题

- 先搜索现有 Issue，确认问题尚未被报告。
- 只提供能够复现问题的最小步骤，并注明 AikoBox、Windows、安装方式及代理模式。
- 必须删除订阅 URL、令牌、密码、UUID、节点地址、个人路径、公网 IP 和完整配置等敏感信息。
- 安全漏洞请按 `SECURITY.md` 私下报告，不要公开可利用细节。

## 提交代码

1. 从 `main` 创建范围单一的分支；不要把无关格式化、重命名或生成文件混入同一 PR。
2. 使用项目声明的 Node.js 与 pnpm 版本安装锁定依赖。
3. 为行为变化添加或更新测试，并同步相关中英文文档。
4. 提交前至少运行：

   ```powershell
   pnpm install --frozen-lockfile --ignore-scripts
   pnpm run review
   pnpm run test:ci
   node --test scripts/prepare.test.mjs
   pnpm run test:licenses
   ```

5. PR 必须通过 `pnpm run review`（格式、lint、类型检查）及 GitHub 的 Windows quality gate，才会进入合并评审。

涉及真实 sing-box 配置的改动还应在隔离环境运行完整 `pnpm test`。不要在依赖现有代理联网的机器上启动开发版、切换系统代理或启用 TUN。

## 二进制与供应链材料

- 不接受来源、版本、哈希和再分发许可未经审计的可执行文件、原生模块、字体、压缩包或预构建前端资源。
- 不要提交 `dist/`、`out/`、`extra/`、私钥、证书、`.env`、访问令牌、订阅内容或真实日志。
- 必须新增运行时资源时，请同时更新资源锁、离线验证测试和第三方许可/来源记录；在许可门禁清零前不得发布该资源的二进制制品。
- 不要通过关闭、跳过或放宽安全、许可证、哈希或签名门禁来让 CI 通过。

## 评审原则

维护者会重点检查兼容性、不断网恢复、权限边界、订阅隐私、回滚路径和测试证据。较大的功能请先开 Issue 说明目标、风险和设计取舍；维护者可能要求拆分 PR。

提交贡献即表示你有权提供这些内容，并同意其按项目的 [GPL-3.0-only](./LICENSE) 许可证发布。
