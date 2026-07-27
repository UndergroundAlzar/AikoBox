# 安全政策 / Security Policy

## 支持范围

安全修复面向最新 GitHub Release 中的：

- Windows 10/11 x64 安装版和便携版
- Android 7.0 及以上的官方 arm64-v8a APK

旧版本、第三方重新打包、自行替换内核或签名的构建，以及仓库中未随 Release 发布的实验客户端不在支持范围内。

## 私密报告漏洞

请优先使用仓库 **Security → Advisories → Report a vulnerability** 提交私密报告。不要在公开 Issue 中披露可利用细节、订阅链接、访问令牌、完整配置或未脱敏日志。

如果私密漏洞报告暂不可用，请只创建不含敏感信息的公开 Issue，请求维护者提供私密渠道。报告建议包含：

- 受影响的 AikoBox、Windows 或 Android 版本
- 安装文件名、设备架构和代理模式
- 可重复的最小步骤、预期影响与实际影响
- 已脱敏的日志、崩溃信息或概念验证
- 公开披露前建议保留的协调时间

## 敏感信息

提交诊断材料前，请删除或替换：

- 订阅 URL、节点地址、用户名、密码、UUID 和证书私钥
- API、控制器、provider、云存储及 GitHub 令牌
- 本机用户名、文件路径、公网 IP、Android 包列表和可识别网络信息
- 代理配置、provider 缓存和日志中的完整请求 URL

维护者不会要求用户上传完整订阅、秘密信息或发布签名密钥。请不要为复现问题关闭杀毒软件、防火墙或当前维持联网的代理/VPN。

## 下载、签名与校验

只从本项目 [GitHub Releases](https://github.com/UndergroundAlzar/AikoBox/releases) 获取官方产物，并使用同一 Release 的 `.sha256` 或统一 `SHA256SUMS.txt`。

- Windows 预发行版在缺少受信任证书时可以作为明确标注的 **UNSIGNED beta** 发布。工作流必须确认安装包、便携版和内部程序均为 `NotSigned`，发布页必须提醒 SmartScreen 风险。
- Android APK 必须由项目固定发布证书签名。证书 SHA-256：
  `8896E81ED78BAACCD385DB95D4591FAA8EC7EF5A87D488258DBA53DA65276B94`
- 每次二进制发布必须通过第三方再分发审计，并附带核心组件的来源、哈希、许可证和对应源码证据。

校验和只能证明文件与发布清单一致，不能替代可信下载来源和代码签名检查。

---

Security fixes cover the latest official Windows x64 and Android arm64-v8a GitHub Release. Report vulnerabilities privately through GitHub Security Advisories. Never publish subscription URLs, credentials, tokens, complete configurations, signing material, or unredacted logs.

Windows prereleases may be distributed only as explicitly identified unsigned betas when a trusted Authenticode identity is unavailable. Android releases must be signed with the fixed project certificate and verified by the release workflow. Download only from this repository's Releases and verify the published SHA-256 checksums.
