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
(set -eu; client_script="$(mktemp)"; trap 'rm -f "$client_script"' EXIT; curl --http1.1 --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 https://raw.githubusercontent.com/m9rco/mlab-gateway-client/v0.3.2/install-client.sh --output "$client_script"; bash "$client_script" --server-url wss://YOUR_SERVER/mlab-tunnel)
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
