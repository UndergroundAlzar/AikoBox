# 安全政策 / Security Policy

## 支持范围

安全修复只面向最新 GitHub Release 的 Windows x64 版本。旧版本、第三方重新打包版本、非 Windows 移植版以及自行替换内核的构建不在支持范围内。

## 私密报告漏洞

请优先使用 GitHub 仓库 **Security → Advisories → Report a vulnerability** 提交私密报告，不要在公开 Issue 中披露可利用细节、订阅链接、访问令牌或个人日志。

如果仓库尚未启用 GitHub 私密漏洞报告，请只创建一条不含敏感信息的公开 Issue，请求维护者提供私密沟通渠道。报告建议包括：

- 受影响的 AikoBox 和 Windows 版本
- 安装版或便携版，以及是否启用了系统代理或 TUN
- 可重复的最小步骤、预期影响和实际影响
- 已脱敏的日志、崩溃信息或概念验证
- 在公开前建议保留的协调时间

维护者确认问题后会给出处理状态；发布时间取决于影响、修复复杂度和第三方组件响应。

## 敏感信息

提交任何诊断材料前，请删除或替换：

- 订阅 URL、节点地址、用户名、密码和 UUID
- API、控制器、provider、云存储及 GitHub 令牌
- 本机用户名、文件路径、公网 IP 和可识别网络信息
- 代理配置、provider 缓存和日志中的完整请求 URL

请不要为了复现问题关闭杀毒软件、防火墙或当前维持联网的代理。不要在没有恢复方案的情况下启用或切换系统代理/TUN。维护者不会要求用户上传完整订阅或秘密信息。

## 下载安全

只从本项目 GitHub Releases 获取官方产物，并使用同一版本中与可执行文件同名的 `.sha256` 文件验证 SHA-256。校验和只能证明文件与发布清单一致，不能替代可信下载来源和 Windows 代码签名检查。正式 tag 发布流程要求安装包和便携版均具有有效 Authenticode 签名。

---

Security fixes cover only the latest official Windows x64 release. Report vulnerabilities privately through GitHub Security Advisories. Never publish subscription URLs, credentials, tokens, complete configurations, or unredacted logs. Do not disable security software or disrupt an active proxy to reproduce a problem. Verify each release artifact against its matching `.sha256` file from the same GitHub Release.
