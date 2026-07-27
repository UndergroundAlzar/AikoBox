# cpx-gateway

机场插件 v2 的参考网关实现。适合先跑通协议的服务商直接部署测试和参考实现使用。

它提供：

- OAuth authorize 登录页：`/oauth/authorize`
- 网关发现文件：`/.well-known/cpx-gateway`
- 网关接口：`/enroll`、`/challenge`、`/config`、`/revoke`
- SQLite 账号、设备和订阅 URL 管理
- Caddy 自动申请和续期 HTTPS 证书

实现只使用 Node.js 内置模块，包括 `node:sqlite`。镜像构建时不执行 `npm install`。

相关文档：

- 中文对接指南：[`docs/plugin/机场服务端对接指南-v2.md`](../../docs/plugin/机场服务端对接指南-v2.md)
- 英文协议文档：[`docs/plugin/PROVIDER_INTEGRATION_v2.md`](../../docs/plugin/PROVIDER_INTEGRATION_v2.md)

---

## 部署结构

默认部署使用一个公网域名，同时作为登录域名和网关域名。

```text
Client browser
  -> https://<domain>/oauth/authorize
  -> Caddy
  -> gateway:8080

Client updater
  -> https://<domain>/.well-known/cpx-gateway
  -> https://<domain>/challenge
  -> https://<domain>/config
  -> Caddy
  -> gateway:8080
  -> hidden subscription origin
```

Compose 服务：

| 服务      | 作用                                           |
| --------- | ---------------------------------------------- |
| `caddy`   | 监听 80/443，申请 Let's Encrypt 证书，反代网关 |
| `gateway` | Node.js 网关进程，只暴露在 compose 内部网络    |

登录请求的客户端 IP 采用显式可信代理策略：

- Compose 把 Caddy 固定在 `172.31.238.2`，gateway 默认只信任该地址提供的
  `X-Forwarded-For`。
- Caddy 会覆盖而不是沿用客户端发送的 `X-Forwarded-For`，因此公网客户端不能伪造
  限流键。
- 非可信来源直连 gateway 时，转发头会被忽略，限流使用连接的 socket 地址。
- 登录同时按客户端 IP 和规范化用户名限流；任一维度达到上限都会返回 `429`。

如果宿主机上的 `172.31.238.0/24` 已被占用，可修改
[`docker-compose.yml`](docker-compose.yml) 中的子网和 Caddy 固定地址，并同步修改
`TRUSTED_PROXY_CIDRS`。不要把该变量设成公网网段或 `0.0.0.0/0`。

数据卷：

| 卷             | 内容                             |
| -------------- | -------------------------------- |
| `gateway_data` | SQLite 数据库 `/data/gateway.db` |
| `caddy_data`   | Caddy 证书和状态                 |
| `caddy_config` | Caddy 运行配置                   |

---

## 前置条件

1. 一台公网 VPS，已安装 Docker 和 Docker Compose v2。
2. 一个域名，A/AAAA 记录已经指向这台 VPS。
3. VPS 防火墙和安全组放行 TCP 80、443。

客户端会校验 HTTPS、公网 host 和 well-known 文件。不要用 IP、`localhost`、内网域名或自签证书部署给真实用户。

---

## 部署

在 VPS 上进入本目录：

```bash
cd deploy/gateway
./deploy.sh
```

首次运行时，脚本会复制 `.env.example` 为 `.env`，询问公网域名，并执行：

```bash
docker compose up -d --build
```

等待 Caddy 申请证书后检查发现文件：

```bash
curl https://<domain>/.well-known/cpx-gateway
```

正常响应类似：

```json
{
  "spec": "cpx-plugin/2",
  "gateway": "https://<domain>",
  "endpoints": {
    "enroll": "/enroll",
    "challenge": "/challenge",
    "config": "/config",
    "revoke": "/revoke"
  }
}
```

查看容器状态：

```bash
docker compose ps
docker compose logs -f gateway
docker compose logs -f caddy
```

---

## 账号管理

每个账号对应一个隐藏订阅 URL。该 URL 由网关在服务端请求，客户端不会拿到。

添加用户：

```bash
docker compose exec gateway cpx-admin add-user alice 'https://origin.example.com/sub?token=xxxx' --limit 3
```

命令会提示输入密码。密码只保存 scrypt hash。

常用命令：

```bash
docker compose exec gateway cpx-admin list-users
docker compose exec gateway cpx-admin list-users --show-sub
docker compose exec gateway cpx-admin set-sub alice 'https://origin.example.com/sub?token=yyyy'
docker compose exec gateway cpx-admin set-limit alice 5
docker compose exec gateway cpx-admin passwd alice
docker compose exec gateway cpx-admin list-devices alice
docker compose exec gateway cpx-admin revoke-device <deviceId>
docker compose exec gateway cpx-admin del-user alice
```

说明：

- `list-users` 默认只显示订阅 URL 的 host。
- `list-users --show-sub` 会打印完整订阅 URL，只在需要排障时使用。
- `revoke-device` 删除设备绑定。客户端下次更新会进入重新登录流程。
- `del-user` 会删除用户及其设备。

---

## 生成 `.cpx`

`.cpx` 是公开插件描述文件，不含用户信息、token、网关密钥或订阅 URL。所有用户可以使用同一份文件。

在仓库根目录运行：

```bash
node scripts/plugin/gen-cpx.mjs https://<domain>/oauth/authorize "Your Airport" https://<domain> your-airport.cpx
```

分发 `your-airport.cpx`。用户在 Clash Party 中导入后，会通过系统浏览器打开登录页。登录成功后，客户端注册设备并拉取该账号绑定的 Clash YAML。

---

## 请求链路

首次登录：

1. 客户端请求 `https://<domain>/.well-known/cpx-gateway`。
2. 客户端生成 Ed25519 设备密钥和 `deviceId`。
3. 系统浏览器打开 `https://<domain>/oauth/authorize?...`。
4. 用户输入账号密码。
5. 网关签发一次性 `code`，绑定 PKCE、`redirect_uri`、`client_id`，TTL 默认 60 秒。
6. 客户端调用 `/enroll`，提交 `code`、PKCE verifier、设备公钥和 `deviceId`。
7. 网关写入设备绑定。

订阅更新：

1. 客户端调用 `/challenge` 领取 nonce。
2. 客户端用设备私钥签名。
3. 客户端调用 `/config`。
4. 网关校验 nonce、时钟偏差和 Ed25519 签名。
5. 网关用该账号的隐藏订阅 URL 拉取 Clash YAML。
6. 网关把 YAML 返回给客户端。

删除插件：

1. 客户端调用 `/revoke`。
2. 网关验签后删除设备绑定。
3. 客户端删除本地状态。

---

## 运维

升级：

```bash
git pull
cd deploy/gateway
./deploy.sh
```

账号和设备数据保存在 `gateway_data` 卷中，升级容器不会删除。

备份数据库到当前目录：

```bash
docker compose exec -T gateway cat /data/gateway.db > gateway.db.backup
```

恢复数据库：

```bash
docker compose down
docker run --rm -i -v gateway_gateway_data:/data busybox sh -c 'cat > /data/gateway.db' < gateway.db.backup
docker compose up -d
```

网关退役：

```bash
if grep -q '^RETIRED=' .env; then
  sed -i.bak 's/^RETIRED=.*/RETIRED=true/' .env
else
  printf '\nRETIRED=true\n' >> .env
fi
docker compose up -d
```

退役后，`/challenge` 和 `/config` 返回 `410` / `gateway_retired`。客户端会回到登录域名重新发现网关。

---

## 配置

配置文件为 `.env`。可参考 [`.env.example`](.env.example)。

| 变量                      | 默认值             | 说明                                                 |
| ------------------------- | ------------------ | ---------------------------------------------------- |
| `DOMAIN`                  | 无                 | 公网域名，必填                                       |
| `PUBLIC_ORIGIN`           | `https://$DOMAIN`  | 写入 `/.well-known/cpx-gateway` 的 gateway origin    |
| `DEVICE_LIMIT_DEFAULT`    | `3`                | 新用户默认设备数上限，可被 `add-user --limit` 覆盖   |
| `CLOCK_SKEW_MS`           | `300000`           | `/config`、`/revoke` 签名时间戳允许偏差              |
| `CODE_TTL_MS`             | `60000`            | authorize code 有效期                                |
| `CODE_POOL_MAX`           | `10000`            | 待兑换 authorize code 的内存容量硬上限               |
| `NONCE_TTL_MS`            | `60000`            | challenge nonce 有效期                               |
| `NONCE_POOL_MAX`          | `8`                | 单设备待用 nonce 数上限                              |
| `LOGIN_MAX`               | `10`               | 单 IP 登录尝试次数上限                               |
| `LOGIN_WINDOW_MS`         | `60000`            | 单 IP 登录限流窗口                                   |
| `LOGIN_ACCOUNT_MAX`       | `10`               | 跨 IP 的单一规范化用户名登录尝试次数上限             |
| `LOGIN_ACCOUNT_WINDOW_MS` | `60000`            | 单用户名登录限流窗口                                 |
| `TRUSTED_PROXY_CIDRS`     | 空                 | 可提供 `X-Forwarded-For` 的代理来源 CIDR，逗号分隔   |
| `SUB_TIMEOUT_MS`          | `30000`            | 拉取隐藏订阅的超时                                   |
| `SUB_MAX_BYTES`           | `10485760`         | 隐藏订阅响应体上限                                   |
| `RETIRED`                 | `false`            | 设置为 `true` 时返回网关退役信号                     |
| `ORIGIN_CA_FILE`          | 空                 | 订阅 origin 使用私有 CA 时，在容器内指定 CA 文件路径 |
| `PORT`                    | `8080`             | gateway 容器内监听端口                               |
| `DB_PATH`                 | `/data/gateway.db` | SQLite 数据库路径                                    |

如果登录域名和网关域名需要拆开，保持 `.cpx` 里的 `loginUrl` 指向登录域名，同时把登录域名上的 `/.well-known/cpx-gateway` 的 `gateway` 指向新的公网网关 origin。当前参考部署默认两者使用同一个域名。

---

## 开发和自测

本目录不需要安装依赖。需要 Node.js >= 22.5.0。

```bash
cd deploy/gateway
npm test
npm run check-vectors
npm start
```

说明：

- `npm test` 使用 `node:test` 跑网关测试。
- `npm run check-vectors` 使用客户端签名向量检查 Ed25519 互通。
- `npm start` 在本地启动 HTTP 网关，默认监听 `:8080`。真实客户端接入仍需要公网 HTTPS 和合法 well-known。

---

## 安全边界

- 隐藏订阅 URL 是管理员配置项。网关只要求 HTTPS，并设置超时和响应体大小上限；不拦截私网地址，便于把 origin 放在内网。
- 密码使用 scrypt hash 保存。
- authorize code 和 nonce 都是一次性短 TTL。
- authorize code 会自动清理过期项并受容量硬上限保护；满载时登录安全失败且不会覆盖有效 code。
- 登录接口按 IP 限流。
- `/config` 和 `/revoke` 使用 Ed25519 设备签名和一次性 nonce 防重放。
- 日志不要记录密码、完整订阅 URL、code、nonce、签名或完整 Clash YAML。
- Clash 节点内容最终会返回客户端，这是客户端运行 Mihomo 的必要输入。本实现保护的是订阅 URL、origin host 和服务端 API。
