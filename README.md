# mlab gateway client

Linux client 的公开安装入口。client 在本机提供 Models / Responses API，使用一条带连接 Token 的持久 WSS 连接访问已部署的 server。支持 x86_64 / aarch64，下载 musl 静态二进制。

```text
本机应用 → 127.0.0.1:8317 + 本地 API Key → client
                                            │ WSS + 连接 Token
                                            ▼
                                          server → 上游
```

需要 server 管理员提供 **WSS 地址与连接 Token**。订阅 OAuth 凭据仅由 server 保存，client 无需登录 OpenAI。发布附件不包含连接 Token 或账户凭据。

## 一键安装

需要 Linux、Bash、curl、tar、sha256sum、常见 coreutils 与可信 CA 证书。公开下载无需 GitHub 登录。将 `YOUR_SERVER` 替换为管理员提供的实际域名，然后执行：

```bash
(set -eu; client_script="$(mktemp)"; trap 'rm -f "$client_script"' EXIT; curl --http1.1 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 https://raw.githubusercontent.com/m9rco/mlab-gateway-client/v0.4.3/install-client.sh --output "$client_script"; bash "$client_script" --server-url wss://YOUR_SERVER/mlab-tunnel)
```

安装器从 `/dev/tty` 隐藏读取连接 Token，不会将它放入命令行参数。它下载并校验同版本附件，生成独立的本地 API Key，保存连接 Token，再配置并按服务模式启动 client。WSS 验证证书链与主机名，生产环境不能跳过 TLS 验证。

无人值守安装可用 `--token-file /path/to/connection-token`，文件须由当前用户拥有、权限为 `0600`；也可用 `--token-stdin` 从标准输入读取 Token。这两种方式与交互输入二选一。不要把 Token 写进命令行、URL、Git 或日志。

## 服务与目录

默认 `--service auto`：有可用的用户 systemd manager 时使用 `user`；否则，root 且有系统 manager 时使用 `system`；其余使用 `none`，打印前台运行命令。也可显式选择模式：

| 模式 | 二进制 / 配置目录 | 启动方式 |
|---|---|---|
| `--service user` | `~/.local/bin` / `${XDG_CONFIG_HOME:-$HOME/.config}/mlab-gateway-client` | 用户服务 `mlab-gateway-client` |
| `--service system` | `/opt/mlab-gateway-client/bin` / `/var/lib/mlab-gateway-client` | 系统服务 `mlab-gateway-client`，需 root |
| `--service none` | 与用户模式相同 | 按安装器输出前台运行，适合容器 |

user / system 默认安装、enable 并启动或重启服务；追加 `--no-start` 只安装就位。system 使用专用非 root 账户 `mlab-gateway-client`，固定目录，不能指定 `--bin-dir` 或 `--config-dir`。user / none 可以用这两个参数指定绝对路径。

用户服务退出终端后继续运行需要管理员配置 `loginctl enable-linger USER`。系统服务无需用户登录会话。管理命令：

```bash
# user 模式
systemctl --user status mlab-gateway-client
journalctl --user -u mlab-gateway-client --since today
# system 模式（root 或 sudo）
sudo systemctl status mlab-gateway-client
sudo journalctl -u mlab-gateway-client --since today
```

首次安装必须指定 `--server-url`。重装可省略并复用已有配置中的地址；明确指定不同地址、Token 或自定义 Key 路径时会停止，要求人工核对，不自动改写旧配置。离线安装可指定 `--release-dir`，目录需包含同版本目标架构归档、SHA256SUMS 和 install.sh；Token 单独安全交付。

## 两种 Key

| 文件 | 用途 |
|---|---|
| `gateway.key` | 安装器为本机生成的 API Key，供本机应用调用 |
| `server.key` | 管理员交付的连接 Token，只供 client 连接 server |

两个 Key 必须不同。配置目录保持私有，Key 文件权限为 `0600`；应用使用 `gateway.key`，无需读取 `server.key`。已有不同的 Token 不会被静默覆盖，轮换时先核对管理员交付的新值。

## 验证与接入

本地 API 默认监听 `127.0.0.1:8317`，完整 Base URL 为 `http://127.0.0.1:8317/v1`；New API 渠道 Base URL 为 `http://127.0.0.1:8317`。当前提供 `/v1/models`、`/v1/responses` 与 `/healthz`，不做 Chat Completions 或 Claude 格式转换。

健康检查使用本地 `gateway.key`。以下为 user / none 的默认目录；system 模式在 root 会话将 `client_config` 改为 `/var/lib/mlab-gateway-client`。自定义安装使用安装器打印的配置路径：

```bash
client_config="${XDG_CONFIG_HOME:-$HOME/.config}/mlab-gateway-client"
curl --fail --silent --show-error \
  --header @<(printf 'Authorization: Bearer %s\n' "$(cat "$client_config/gateway.key")") \
  http://127.0.0.1:8317/healthz
```

命令从文件构造鉴权头，Key 不放入 curl 参数。初次连接尚未就绪时可能返回 `503`，稍后重试健康检查。server 未完成上游授权时，Models / Responses 也会返回 `503`；健康正常不代表真实模型生成已成功。

连接中断会使当前请求失败；client 后台重连后接收新请求，已提交的生成不会自动重放。不要自动重试已经提交的生成请求。

Docker 中安装时指定 `--service none`，随后以前台 `client serve` 运行；无需容器中的 systemd。容器内的 `127.0.0.1` 指向容器自身，本机应用与 client 应处在同一网络环境中。

许可证：[MIT](LICENSE)。

## v0.3.5 诊断与兼容性

原生客户端增加已鉴权的本机 `/diagnostics`，显示当前 WSS 心跳 RTT、最近 32 个样本的统计及年龄，断线不返回旧样本，重连重新采样。它与本机 Responses 使用相同的本地 Bearer key。服务端与客户端补齐固定 Codex CLI 0.162.1 消费的模型、推理、安全缓冲和基础额度响应头；v1 隧道协议不变。

需要 npm 包装器和逐跳诊断时使用 `@m9rco/mcodex`。`mcodex ping` 的 HK→SG 探针需要网关管理员先安装对应 nginx 配置；它区分相邻 TCP/TLS 建连和累计响应头耗时，并不会把它们误报为单跳网络 RTT。`ping --compare <WSS URL>` 可从实际客户端所在地比较中转与直连，比较目标须属于同一受信任网关并接受同一个 Token。

0.4.1 新客户端与服务端协商 v2 隧道后默认每次请求最多 16 MiB，硬上限 32 MiB；与旧端连接时保留 v1 的 1 MiB 上限并明确返回 413。现有配置中显式的 `max_body_bytes` 会保留，升级前应核对两端限制。请求体字节上限与模型 token 窗口分别控制，不截断消息、不自动重放。大请求在读取前按预算准入，预算繁忙返回 429。当前完整验收范围为 HTTP Responses/SSE、本地工具、本地摘要压缩、resume、取消和断线不重放；不代表支持所有未来 Codex 或公共 OpenAI API 功能。

## v0.4.1 版本隔离与长请求

支持官方 Codex 0.162.1 和 0.163.0 的兼容测试。mcodex 可显式选择独立安装的 Codex，引擎、包装器和网关分别维护；默认版本在测试后更新，不会自动追随最新版本。网关保留旧 v1 编码及连接兼容性，新 v2 仅在已鉴权 WSS 建连时协商请求体上限。诊断会显示实际协议和有效上限；内存预算只限制原始请求体工作集，不代表整个进程 RSS。

## v0.4.2 慢上传与错误定位

修复大请求尚在写入时误判 Pong 超时而断线；Ping 写出后才开始等待 Pong，写入另有默认 30 秒预算。HTTP 取消后排队或写入中的原始数据继续占用内存许可，写出或丢弃后才释放。真实断线仍不重放已提交请求。服务端默认心跳失联预算为 45 秒，单独扩大客户端写入预算不能允许无限慢上传。

本机诊断新增安全的最近建连失败阶段与固定错误码，显示已鉴权握手观察到的服务端版本。握手连接数量/帧预留预算 429 与请求体 413、模型上下文超限不同。默认服务端 128 MiB 请求预算将其中 64 MiB 用于连接帧预留，16 MiB v2 隧道可预留 4 条；比较探测占两条，不盲目扩大限制。
