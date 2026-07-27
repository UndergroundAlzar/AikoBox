# 参与贡献

感谢你愿意改进 AikoBox。项目当前发布 Windows x64 和 Android arm64-v8a Beta；开始前请阅读 [README.md](./README.md)、[英文 README](./README_EN.md) 和 [SECURITY.md](./SECURITY.md)。

## 提交问题

- 先搜索现有 Issue，确认问题尚未被报告。
- 注明平台、AikoBox 版本、安装文件、系统版本、设备架构和代理模式。
- 只提供可重复的最小步骤，并删除订阅 URL、令牌、密码、UUID、节点地址、个人路径、公网 IP 和完整配置。
- 明确区分当前 Release 使用的 `apps/android/` 与实验客户端 `mobile/`。
- 安全漏洞按 `SECURITY.md` 私下报告，不要公开可利用细节。

## 提交代码

1. 从 `main` 创建范围单一的分支，不要混入无关格式化、重命名或生成文件。
2. 使用仓库和工作流锁定的 Node.js、pnpm、Flutter、Go、JDK、Android SDK 与 NDK 版本。
3. 为行为变化添加或更新测试，并同步中英文文档和能力说明。
4. Windows/共享代码提交前至少运行：

   ```powershell
   pnpm install --frozen-lockfile --ignore-scripts
   pnpm run review
   pnpm run test:ci
   pnpm run test:licenses
   ```

5. Android `apps/android/` 改动应运行：

   ```powershell
   cd apps/android
   flutter analyze
   flutter test
   ```

6. Android 原生和 libbox 改动还必须通过 GitHub 的 Android 质量任务；不要用调试签名或第三方 AAR 代替发布门禁。

PR 必须通过统一的 Windows 与 Android quality gate。涉及真实 sing-box 配置的改动还应在隔离环境运行完整 `pnpm test`。不要在依赖现有代理联网的机器上随意启动开发版、切换系统代理或启用 TUN/VPN。

## 两套 Android 代码

- `apps/android/` 是当前公开 APK 的源码，修改会进入统一质量和 Release 流程。
- `mobile/` 是实验中的下一代客户端，有独立质量工作流，不代表当前 Release 能力。

提交时只改与目标对应的代码树。跨树复用转换、订阅或测试语料时，应提供一致性测试，避免两端行为漂移。

## 二进制与供应链材料

- 不接受来源、版本、哈希和再分发许可未经审计的可执行文件、原生模块、字体、压缩包或预构建资源。
- 不要提交 `dist/`、`out/`、私钥、证书、`.env`、访问令牌、订阅内容或真实日志。
- 新增运行时资源时，同时更新资源锁、离线验证测试和第三方许可/来源记录。
- 不要通过关闭、跳过或放宽安全、许可证、哈希、ABI 或签名门禁来让 CI 通过。

## 评审原则

维护者重点检查兼容性、不断网恢复、权限边界、订阅隐私、回滚路径和测试证据。较大的功能请先开 Issue 说明目标、风险和设计取舍；必要时拆分 PR。

提交贡献即表示你有权提供这些内容，并同意其按 [GPL-3.0-only](./LICENSE) 许可证发布。
