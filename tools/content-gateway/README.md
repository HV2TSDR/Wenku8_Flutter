# 文库公共内容备用网关

域名：`https://app.3952039.xyz`，Worker：`wenku8-public`。

原文库 API 已使用 Cloudflare。叠加书目反代的实测返回上游错误且更慢，因此本服务只处理图片，不替换书目或账号链路，也不是整个文库网站的镜像。App 保留实测更快的原图片源，失败后才使用备用网关。

- 不提供 POST／API 路由，书目、登录、账号、个人书架和章节正文均保留原链路。携带 Cookie 或 Authorization 的请求直接拒绝。
- `GET /image/{base64url}`：只接受已知图片主机及图片目录，不接收任意目标 URL、凭据或查询参数。保持图片原始字节，不使用收费图片处理。
- `GET /health`：状态、粗略国家与边缘机房，不返回访问者 IP。

`PublicBudget` 使用免费 SQLite Durable Object 全局计数，每天最多接纳 5,000 次，UTC 零点重置。接纳量包括缓存命中和上游失败；旧计数原位覆盖。超过后返回距下一日的 `Retry-After`，App 按此停止备用请求。

每 IP 每分钟 90 次，App 最多两个备用并发，版本检查与 APK 下载期间不发新增备用请求。账号级额度与接纳量的区别、防滥用及恢复策略见[更新镜像维护说明](../update-mirror/README.md)。

```sh
node --test worker.test.mjs
npx wrangler versions upload
npx wrangler versions deploy 版本ID@100% --yes
```

自定义域名在控制台维护，默认与预览 workers.dev 关闭。只保存公共内容缓存和计数，不配置文库账号凭据。
