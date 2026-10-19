# 轻小说文库更新镜像

打开 <https://git.3952039.xyz> 查看介绍、更新说明并下载正式版。App 读取 `/api/releases/latest` 检查更新，镜像限流、超时或连接失败后自动直连 GitHub，无需选择来源。

介绍页作为免费 Static Asset 提供，不执行 Worker、不占十万次动态请求额度；版本接口或下载网关不可用时，页面脚本仍可直接读取 GitHub 并选择原站下载。

只服务 `mikufoxxx/Wenku8_Flutter` 的公开正式发布。0.4.1 以 0.3.7 为功能底座，使用更高构建号供 0.4.0 用户覆盖升级，历史正式版附件恢复下载；0.4.0 已撤回，在任何附件缓存读取前返回 410。版本 JSON 保留原始 GitHub 下载地址、资产 ID、大小和 digest，客户端验证后再映射到本站。下载地址为原 GitHub 路径，域名替换为本站，并追加 `?asset=资产ID`。不接收任意目标地址，也不转发访问者的 Cookie 或 Authorization。

## 部署与维护

- Worker：`wenku8-update`，Custom Domain：`git.3952039.xyz`。DNS 和 TLS 由 Cloudflare 管理。
- Workers Free，当前套餐 US$0。全账号每天共享 100,000 次 Worker 请求；UTC 00:00／北京时间 08:00 重置。每次 CPU 10 ms、内存 128 MB，无额外出站流量费。额度用完停止服务，不自动升级。
- 两个免费 SQLite Durable Object 只保存公开发布清单和公共请求计数。免费额度为每日 100,000 次请求、13,000 GB-s、读 500 万行、写 10 万行及总存储 5 GB。保持 Free，不启用 R2、付费加速或自动扩容；手动升级 Paid 会改变零费用前提。
- 维护脚本只需 Wrangler 的账号读取、用户读取和 Worker 脚本写入权限。先 `npx wrangler versions upload`，再将返回版本 ID 通过 `npx wrangler versions deploy 版本ID@100% --yes` 上线。自定义域名在控制台管理，不需要把 DNS 修改权限授予 CLI。
- `ReleaseRegistry` 在机房之间共用清单，合并并发请求，每 120 秒最多刷新一次最新版本。八个恢复的公开版本使用固定标签白名单，按需核验；未知历史标签不触发 GitHub API 请求。边缘缓存最新清单 120 秒，已知标签清单 300 秒。APK 流式转发，按资产 ID 缓存 1 小时，支持 HEAD 和 Range，不将部分响应存成完整包。
- 版本检测不使用失败后的过期回退清单。下载已有明确身份的包时，可使用 24 小时内验证的清单。回滚采用新缓存命名空间，不继承 0.4.0 清单或重新上传前的资产 ID。已验证的资产缓存可独立于版本接口读取；0.4.0 始终提前阻断。
- GitHub 共享出口可能返回 403／429。App 和下载页自动回退；可选只读 `GITHUB_TOKEN` 只能保存到 Cloudflare 加密 Secret，不能放在源码、普通 vars 或前端。
- 客户端仍核对 APK 长度、GitHub digest（如提供）、包名、版本、构建号和签名。
- `/health` 返回服务状态及当前 Cloudflare 边缘机房代码，不返回访问者 IP。
- App 回退下载前清除未完成文件并重置进度，核对原站同一资产 ID、大小及 digest。取消、身份变化和校验失败不会换源。控制台可回滚兼容当前 Durable Object 类的 Worker 版本。
- 默认 `workers.dev` 和预览入口关闭，避免绕过自定义域名的安全规则。

### 配置 GitHub 只读凭据

共享出口遇到 GitHub 403／429 时，在 GitHub 创建 Fine-grained token，仓库访问选择 **Only select repositories → mikufoxxx/Wenku8_Flutter**。只授予 **Contents: Read-only** 和必需的 **Metadata: Read-only**，不添加账号或写入权限。GitHub 固有的公开资源只读访问不受所选仓库限制；此配置不授予其他私有仓库权限，Worker 的回源路径仍固定为文库仓库。

在 `wenku8-update → 设置 → 运行时变量和密钥` 中添加生产环境 `GITHUB_TOKEN`，勾选「密钥」并部署。值保存在加密 Secret 中，不写进 Wrangler vars、源码或前端。现有 App 不需要为服务端凭据变更重新安装。

当前部署按维护者选择使用 **No expiration（不设到期日）**。需要轮换时，先创建同权限的新凭据，替换 Secret 并验证 `/api/releases/latest` 返回正常正式版，再撤销旧凭据；若其他部署设置了到期日，应在到期前轮换。凭据失效时仍保留缓存规则和自动直连兜底。

## 防滥用

- 更新查询与下载始终优先。`app.3952039.xyz` 公共网关由独立全局计数每天只接纳 5,000 次，App 更新期间暂停新增备用请求；收到限额后按 `Retry-After` 停用直到次日，不反复重试。
- 原文库接口已有 Cloudflare，叠加书目反代的实测返回上游错误，因此书目保留原链路。原图片源也更快，封面与插图只在故障时使用图片备用网关，不增加正常浏览延迟。账号、登录、个人书架和章节正文不进入网关。
- 5,000 是公共业务接纳量，不是账号级硬隔离。网关内部拒绝仍消耗 Worker 请求；WAF 先挡无关路径，分布式攻击仍可能耗尽免费额度，此时 App 自动直连。

- Worker 原生限流：公开查询每 IP 每分钟 120 次；下载请求每 IP 每分钟 30 次，超出返回 429 与 `Retry-After: 60`。移动网络可能共享出口，限流不作为用户身份验证。
- 免费 WAF 速率规则 `Wenku mirror burst guard`：仅匹配 `git.3952039.xyz`，每 IP 每 10 秒超过 60 次则阻止 10 秒。
- 免费 WAF 自定义规则 `Wenku mirror route allowlist`：仅此主机名、GET/HEAD、首页/健康/版本接口及固定文库发布路径；其他路径在 Worker 之前拦截。Worker 再检查正式版本、文件名、资产 ID 和大小。
- 地址和源码可以公开；没有 App 内置共享密钥，不依赖可伪造的 Referer 或 User-Agent。别人无法借本站代理其他仓库，但分布式恶意请求仍可能耗尽免费额度，造成暂时不可用，而非额外账单。

运行测试：`node --test worker.test.mjs`。

## 大陆线路与 IP

使用 Cloudflare 官方 Custom Domain 的 Anycast 调度，不写死所谓「香港 IP」。同一 IP 会在多个机房宣告，入口取决于用户运营商路由。免费全球网络不等于中国大陆节点；本机测速不能代表全国电信、联通、移动。

已按要求通过 Bing 查阅 [CMLiussss 的域名优选教程](https://blog.cmliussss.com/p/BestWorkers/)。测试保持本站 Host、TLS SNI 和证书校验，直接核对优选入口能否服务自己的 Worker，再比较首字节与下载；不把 IP 地理库或单条线路当成全国结论。正式入口保留受支持的 Custom Domain，不未经测试撤掉托管 DNS 或引入第三方 NS。

[CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 可用于对应网络的实测优选；其作者在[旧版 Worker 自选 IP 教程](https://github.com/XIU2/CloudflareSpeedTest/discussions/310)中已说明方案失效，因此没有按旧教程改动正式域名的托管 DNS。没有大陆三网测试证据前，不把本机测到的地址作为全国默认入口。

参考：[Worker 部署](https://developers.cloudflare.com/workers/get-started/dashboard/)、[自定义域名](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/)、[Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/)、[Anycast 路由说明](https://developers.cloudflare.com/support/troubleshooting/general-troubleshooting/geographic-traffic-routing/)、[免费额度](https://developers.cloudflare.com/workers/platform/limits/)。
