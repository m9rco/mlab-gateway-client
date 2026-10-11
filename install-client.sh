#!/usr/bin/env bash
# Public, anonymous client bootstrap. OAuth credentials stay on the server.
# Turn off inherited tracing before reading any connection token.
set +x
set -euo pipefail
umask 077

repo=m9rco/mlab-gateway-client
version=v0.3.2
bin_dir="${HOME}/.local/bin"
config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/mlab-gateway-client"
release_dir=""
server_url=""
service=auto
bin_dir_explicit=false
config_dir_explicit=false
runtime_uid="$EUID"
runtime_gid=""
public_stage=""
runtime_work=""
unit_tmp=""
start_service=true
token_source=""
token_stdin=false
stage=""
key_tmp=""
config_tmp=""
typed_token=""

die() { printf '客户端安装失败：%s\n' "$*" >&2; exit 1; }
cleanup() {
  local result=$?
  trap - EXIT
  set +e
  unset typed_token
  [[ -z "$stage" ]] || rm -rf -- "$stage"
  [[ -z "$key_tmp" ]] || rm -f -- "$key_tmp"
  [[ -z "$config_tmp" ]] || rm -f -- "$config_tmp"
  [[ -z "$public_stage" ]] || rm -rf -- "$public_stage"
  [[ -z "$runtime_work" ]] || rm -rf -- "$runtime_work"
  [[ -z "$unit_tmp" ]] || rm -f -- "$unit_tmp"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<'USAGE'
Usage: bash install-client.sh --server-url wss://YOUR_SERVER/mlab-tunnel [options]
  --version v0.3.2          Public release tag (default: v0.3.2)
  --repo OWNER/REPO         Default: m9rco/mlab-gateway-client
  --release-dir PATH       Offline archive, SHA256SUMS and install.sh directory
  --bin-dir PATH           Default: ~/.local/bin
  --config-dir PATH        Default: ${XDG_CONFIG_HOME:-~/.config}/mlab-gateway-client
  --server-url URL         WSS server endpoint; required for the first installation
  --token-file FILE        Read connection token from an owned, ordinary 0600 file
  --token-stdin            Read the connection token from standard input
  --service auto|user|system|none
                           Default: auto (user manager, then root system manager, else none)
  --no-start               Install/enable a service without start or restart
  --help

Without --token-file or --token-stdin, read the token silently from /dev/tty.
Token contents are never accepted as a command-line argument or printed.
Downloads are anonymous HTTPS; GitHub login and server SSH login are unnecessary.
Existing keys/configuration are preserved. A different token or server URL is rejected.
Custom key paths and old SSH client configuration require manual migration.
Service 'none' prints the command for foreground execution (also suitable for Docker).
System service requires root and runs as the dedicated mlab-gateway-client account.
Its fixed paths are /opt/mlab-gateway-client/bin and /var/lib/mlab-gateway-client.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--repo|--release-dir|--bin-dir|--config-dir|--server-url|--token-file|--service)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 缺少值"
      option="$1"; value="$2"; shift 2
      case "$option" in
        --version) version="$value" ;;
        --repo) repo="$value" ;;
        --release-dir) release_dir="$value" ;;
        --bin-dir) bin_dir="$value"; bin_dir_explicit=true ;;
        --config-dir) config_dir="$value"; config_dir_explicit=true ;;
        --server-url) server_url="$value" ;;
        --token-file) token_source="$value" ;;
        --service) service="$value" ;;
      esac ;;
    --token-stdin) token_stdin=true; shift ;;
    --no-start) start_service=false; shift ;;
    --help|-h) usage; exit 0 ;;
    --token) die '不接受明文 --token；请使用 --token-file、--token-stdin 或静默交互输入' ;;
    *) die '未知选项；请使用 --help（Token 只能从文件、stdin 或静默提示输入）' ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '仓库格式必须是 OWNER/REPO'
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '版本必须是 vMAJOR.MINOR.PATCH'
[[ "$service" == auto || "$service" == user || "$service" == system || "$service" == none ]] || die '--service 必须为 auto、user、system 或 none'
[[ -z "$token_source" ]] || ! "$token_stdin" || die '--token-file 与 --token-stdin 不能同时使用'
[[ "$(uname -s)" == Linux ]] || die '预编译客户端仅支持 Linux；其他平台请编译源码'
case "$(uname -m)" in
  x86_64|amd64) target=x86_64-unknown-linux-musl ;;
  aarch64|arm64) target=aarch64-unknown-linux-musl ;;
  *) die '只提供 x86_64 / aarch64 Linux 客户端安装包' ;;
esac
for command in awk cmp cp head mktemp install sha256sum stat tr; do
  command -v "$command" >/dev/null || die "缺少依赖：$command"
done

file_mode() {
  local mode
  if ! mode=$(stat -c '%a' -- "$1" 2>/dev/null); then mode=$(stat -f '%Lp' "$1") || return 1; fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  printf '%s' "$mode"
}
regular_file() {
  [[ ! -L "$1" && -f "$1" && -r "$1" ]] || die "$2 必须为可读普通文件，不能是符号链接：$1"
}
file_uid() {
  local uid
  if ! uid=$(stat -c '%u' -- "$1" 2>/dev/null); then uid=$(stat -f '%u' "$1") || return 1; fi
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$uid"
}
private_file() {
  local mode owner
  regular_file "$1" "$2"
  owner=$(file_uid "$1") || die "无法检查 $2 归属"
  [[ "$owner" == "${3:-$EUID}" ]] || die "$2 的文件所有者与运行账户不符：$1"
  mode=$(file_mode "$1") || die "无法检查 $2 权限"
  (( 8#$mode == 0600 )) || die "$2 权限必须为 0600；不会修改已有文件：$1"
}
private_directory() {
  local mode owner
  [[ ! -L "$1" && -d "$1" ]] || die '配置目录必须为普通目录，不能是符号链接'
  owner=$(file_uid "$1") || die '无法检查配置目录归属'
  [[ "$owner" == "${2:-$EUID}" ]] || die '配置目录所有者与运行账户不符；不会修改已有目录归属'
  mode=$(file_mode "$1") || die '无法检查配置目录权限'
  (( 8#$mode == 0700 )) || die '已有配置目录权限必须为 0700；不会修改已有目录'
}
key_file() {
  private_file "$1" "$2" "${3:-$EUID}"
  LC_ALL=C awk 'NR != 1 || length($0) < 32 || length($0) > 4096 || $0 ~ /[^!-~]/ { bad=1 }
    END { exit (NR == 1 && !bad) ? 0 : 1 }' "$1" || die "$2 必须为单行、至少 32 字符的无空白 ASCII Token"
}
keys_equal() {
  # Inputs already pass key_file; a final newline is not part of the token.
  LC_ALL=C awk 'NR == 1 { first=$0; next } $0 != first { exit 1 }' "$1" "$2"
}
clean_absolute_path() {
  [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]] || die "$2 必须为无换行的绝对路径"
  [[ "$1" != *'"'* && "$1" != *$'\\'* ]] || die "$2 含有需要 TOML 转义的字符；请使用普通路径或手动安装"
}
validate_url() {
  local authority port
  (( ${#1} <= 2048 )) || die 'server_url 过长'
  [[ "$1" =~ ^wss://([A-Za-z0-9][A-Za-z0-9.-]*|\[[A-Fa-f0-9:]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] || die 'server_url 必须为 WSS URL，且不包含用户信息、查询参数、片段或需要转义的字符'
  authority=${1#*://}; authority=${authority%%/*}; port=${authority##*:}
  if [[ "$port" =~ ^[0-9]+$ ]]; then (( 10#$port >= 1 && 10#$port <= 65535 )) || die 'server_url 端口无效'; fi
}
config_string() {
  LC_ALL=C awk -v name="$2" '
    $0 ~ "^[[:space:]]*" name "[[:space:]]*=" {
      count++; line=$0; sub(/^[^=]*=[[:space:]]*/, "", line)
      if (line !~ /^"[^"\\]*"[[:space:]]*(#.*)?$/) { bad=1; next }
      sub(/^"/, "", line); sub(/"[[:space:]]*(#.*)?$/, "", line); value=line
    }
    END { if (count != 1 || bad) exit 1; print value }' "$1"
}
check_config() {
  local api_path server_path existing_url
  private_file "$config_file" 'config.toml' "$runtime_uid"
  if LC_ALL=C awk '/^[[:space:]]*(ssh_target|ssh_port|ssh_identity_file|server_port|relay_url|managed_ssh)[[:space:]]*=/ { found=1 }
      END { exit !found }' "$config_file"; then die '旧 SSH client 配置需要手动迁移；不会覆盖已有配置'; fi
  api_path=$(config_string "$config_file" api_key_file) || die 'api_key_file 必须为唯一的简单双引号 TOML 字符串'
  server_path=$(config_string "$config_file" server_key_file) || die 'server_key_file 必须为唯一的简单双引号 TOML 字符串'
  [[ "$api_path" == "$local_key" || "$api_path" == gateway.key ]] || die '已有 api_key_file 指向自定义路径；请手动迁移，不会盲目复制密钥'
  [[ "$server_path" == "$server_key" || "$server_path" == server.key ]] || die '已有 server_key_file 指向自定义路径；请手动迁移，不会盲目复制密钥'
  existing_url=$(config_string "$config_file" server_url) || die 'server_url 必须为唯一的简单双引号 TOML 字符串'
  validate_url "$existing_url"
  if [[ -z "$server_url" ]]; then server_url="$existing_url"; fi
  if ! "$new_config" && [[ "$existing_url" != "$server_url" ]]; then
    die '已有 server_url 与指定服务器不同；配置已保留，请手动核对后修改'
  fi
}
escape_unit() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//%/%%}; printf '%s' "$s"; }
unit_property() {
  LC_ALL=C awk -v property="$2" '
    /^[[:space:]]*\[/ { section=$0; gsub(/^[[:space:]]*|[[:space:]]*$/, "", section) }
    section == "[Service]" && $0 ~ "^[[:space:]]*" property "[[:space:]]*=" {
      line=$0; sub(/^[[:space:]]*/, "", line); print line
    }' "$1"
}
check_unit() {
  local actual expected mode
  regular_file "$unit_path" 'client systemd unit'
  if [[ "$service" == system ]]; then
    [[ "$(file_uid "$unit_path")" == 0 ]] || die 'system client unit 必须为 root 所有'
    [[ "$(unit_property "$unit_path" User)" == User=mlab-gateway-client ]] || die 'system client unit 必须使用专用非 root User'
    [[ "$(unit_property "$unit_path" Group)" == Group=mlab-gateway-client ]] || die 'system client unit 必须使用专用 Group'
  else
    [[ -O "$unit_path" ]] || die 'client unit 必须由当前用户拥有'
  fi
  mode=$(file_mode "$unit_path") || die '无法检查 client unit 权限'
  (( (8#$mode & 022) == 0 )) || die 'client unit 不能允许其它用户写入'
  expected="ExecStart=\"$(escape_unit "$bin_dir/mlab-gateway")\" --config \"$(escape_unit "$config_file")\" client serve"
  actual=$(unit_property "$unit_path" ExecStart)
  [[ "$actual" == "$expected" ]] || die '已有 client unit 的 ExecStart / 配置路径不匹配；未更改或启动此 unit'
}

has_user_manager() {
  command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1
}
has_system_manager() {
  # Query the running manager, rather than checking whether systemctl is installed.
  command -v systemctl >/dev/null &&
    systemctl show --property=Version >/dev/null 2>&1
}
if [[ "$service" == auto ]]; then
  if has_user_manager; then service=user
  elif (( EUID == 0 )) && has_system_manager; then service=system
  else service=none; fi
elif [[ "$service" == user ]]; then
  has_user_manager || die 'user systemd manager 不可用；请使用 --service none 前台运行'
elif [[ "$service" == system ]]; then
  (( EUID == 0 )) || die 'system 模式需要 root / sudo'
  has_system_manager || die '没有可用的 systemd 系统 manager；容器请使用 --service none'
fi
if [[ "$service" == system ]]; then
  if "$bin_dir_explicit" || "$config_dir_explicit"; then
    die 'system 模式使用固定目录，不接受 --bin-dir / --config-dir'
  fi
  bin_dir=/opt/mlab-gateway-client/bin
  config_dir=/var/lib/mlab-gateway-client
  unit_path=/etc/systemd/system/mlab-gateway-client.service
  for command in getent id useradd runuser tar chown; do
    command -v "$command" >/dev/null || die "system 模式缺少依赖：$command"
  done
  runtime_uid=""
  if getent passwd mlab-gateway-client >/dev/null; then
    runtime_uid=$(id -u mlab-gateway-client)
    runtime_gid=$(id -g mlab-gateway-client)
    if [[ ! "$runtime_uid" =~ ^[0-9]+$ || ! "$runtime_gid" =~ ^[0-9]+$ ]] || (( runtime_uid == 0 || runtime_gid == 0 )); then
      die '专用运行账户不能使用 root UID/GID'
    fi
    account=$(getent passwd mlab-gateway-client)
    IFS=: read -r _ _ _ _ _ account_home account_shell <<< "$account"
    [[ "$account_home" == "$config_dir" && ( "$account_shell" == /sbin/nologin || "$account_shell" == /usr/sbin/nologin ) ]] || die '已有同名账户不是预期的专用服务账户；未修改'
  elif [[ -e "$config_dir" || -L "$config_dir" ]]; then
    die 'system 状态目录已存在但专用账户不存在；请先人工核对，不会更改目录归属'
  fi
elif [[ "$service" == user ]]; then
  unit_path="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/mlab-gateway-client.service"
fi
clean_absolute_path "$bin_dir" '--bin-dir'
clean_absolute_path "$config_dir" '--config-dir'
while [[ "$bin_dir" != / && "$bin_dir" == */ ]]; do bin_dir=${bin_dir%/}; done
while [[ "$config_dir" != / && "$config_dir" == */ ]]; do config_dir=${config_dir%/}; done
config_file="$config_dir/config.toml"
local_key="$config_dir/gateway.key"
server_key="$config_dir/server.key"
new_config=true
if [[ -e "$config_dir" || -L "$config_dir" ]]; then private_directory "$config_dir" "$runtime_uid"; fi
if [[ -e "$config_file" || -L "$config_file" ]]; then
  new_config=false
  check_config
  key_file "$local_key" '已有本地 gateway.key' "$runtime_uid"
elif [[ -e "$local_key" || -L "$local_key" ]]; then
  key_file "$local_key" '已有本地 gateway.key' "$runtime_uid"
fi
[[ -n "$server_url" ]] || die '首次安装必须指定 --server-url wss://YOUR_SERVER/mlab-tunnel'
validate_url "$server_url"
if [[ -e "$server_key" || -L "$server_key" ]]; then
  key_file "$server_key" '已有 server.key' "$runtime_uid"
  if [[ -e "$local_key" ]]; then ! keys_equal "$server_key" "$local_key" || die '已有 server.key 与本地 gateway.key 必须不同'; fi
fi
[[ -z "$token_source" ]] || key_file "$token_source" '--token-file'
if [[ -n "$release_dir" ]]; then
  [[ "$release_dir" != *$'\n'* && "$release_dir" != *$'\r'* && "$release_dir" != *$'\t'* && -d "$release_dir" ]] || die '--release-dir 必须是无换行的已有目录'
fi

if [[ "$service" != none && ( -e "$unit_path" || -L "$unit_path" ) ]]; then check_unit; fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/mlab-client-bootstrap.XXXXXXXX")
if [[ -n "$token_source" ]]; then
  cp -- "$token_source" "$stage/connection-token"
elif "$token_stdin"; then
  # Bound input, while preserving newline/whitespace for strict format validation.
  head -c 4098 > "$stage/connection-token"
else
  if ! { printf '输入连接 Token（不显示）：' > /dev/tty; } 2>/dev/null; then
    die '没有交互终端；请使用 --token-file 或 --token-stdin'
  fi
  if ! IFS= read -r -s typed_token < /dev/tty; then unset typed_token; die '未读取到连接 Token'; fi
  printf '\n' > /dev/tty
  printf '%s\n' "$typed_token" > "$stage/connection-token"
  unset typed_token
fi
token_source="$stage/connection-token"
key_file "$token_source" '连接 Token'
if [[ -e "$server_key" ]]; then keys_equal "$token_source" "$server_key" || die '连接 Token 与已有 server.key 不同；不会覆盖'; fi
if [[ -e "$local_key" ]]; then ! keys_equal "$token_source" "$local_key" || die '连接 Token 与本地 gateway.key 相同；必须使用不同的密钥'; fi

archive="mlab-gateway-${version}-${target}.tar.gz"
assets=("$archive" SHA256SUMS install.sh)
if [[ -n "$release_dir" ]]; then
  for asset in "${assets[@]}"; do
    regular_file "$release_dir/$asset" "离线附件 $asset"
    cp -- "$release_dir/$asset" "$stage/$asset"
  done
else
  command -v curl >/dev/null || die '匿名 HTTPS 下载需要 curl'
  for asset in "${assets[@]}"; do
    curl --http1.1 --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
      --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      "https://github.com/${repo}/releases/download/${version}/${asset}" --output "$stage/$asset" || die '公开发行包下载失败；请检查网络、仓库和版本'
  done
fi
for asset in "${assets[@]}"; do regular_file "$stage/$asset" "下载附件 $asset"; done
for asset in "$archive" install.sh; do
  expected=$(LC_ALL=C awk -v wanted="$asset" '$2 == wanted || $2 == "*" wanted { print $1 }' "$stage/SHA256SUMS")
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "$asset 缺少唯一 SHA-256；未执行安装脚本"
  actual=$(sha256sum "$stage/$asset"); actual=${actual%% *}
  expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
  [[ "$actual" == "$expected" ]] || die "$asset SHA-256 不匹配；未执行安装脚本"
done

if [[ "$service" == system ]]; then
  # Account and directory mutations happen only after the complete release is verified.
  if [[ -z "$runtime_uid" ]]; then
    useradd --system --user-group --no-create-home --home-dir "$config_dir" --shell /sbin/nologin mlab-gateway-client
    runtime_uid=$(id -u mlab-gateway-client); runtime_gid=$(id -g mlab-gateway-client)
    (( runtime_uid != 0 && runtime_gid != 0 )) || die '专用运行账户必须为非 root'
  fi
  if [[ ! -e "$config_dir" && ! -L "$config_dir" ]]; then
    install -d -m 700 -o "$runtime_uid" -g "$runtime_gid" "$config_dir"
  fi
  private_directory "$config_dir" "$runtime_uid"
  for directory in /opt/mlab-gateway-client "$bin_dir"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      [[ ! -L "$directory" && -d "$directory" && "$(file_uid "$directory")" == 0 ]] || die 'system 二进制目录必须是 root 所有的普通目录'
      mode=$(file_mode "$directory") || die '无法检查 system 二进制目录权限'
      (( (8#$mode & 022) == 0 )) || die 'system 二进制目录不能允许其它用户写入'
    else
      install -d -m 755 -o root -g root "$directory"
    fi
  done
  # Public assets are root-owned and immutable to the runtime account. The private
  # connection-token stage remains 0700 and is never shared with the installer.
  public_stage=$(mktemp -d "${TMPDIR:-/tmp}/mlab-client-public.XXXXXXXX")
  chmod 755 "$public_stage"
  for asset in "${assets[@]}"; do install -m 644 "$stage/$asset" "$public_stage/$asset"; done
  [[ "$(tar -tzf "$public_stage/$archive")" == mlab-gateway ]] || die '归档包含意外路径'
  details=$(tar -tvzf "$public_stage/$archive") || die '无法读取归档类型'
  [[ "${details:0:1}" == '-' ]] || die '归档中的二进制必须为普通文件'
  tar -xOzf "$public_stage/$archive" -- mlab-gateway > "$public_stage/mlab-gateway"
  chmod 755 "$public_stage/mlab-gateway"
  [[ "$(runuser -u mlab-gateway-client -- "$public_stage/mlab-gateway" --version)" == "mlab-gateway ${version#v}" ]] || die '二进制版本与发行版本不符'
  runtime_work=$(mktemp -d "${TMPDIR:-/tmp}/mlab-client-work.XXXXXXXX")
  chown "$runtime_uid:$runtime_gid" "$runtime_work"
  runuser -u mlab-gateway-client -- bash "$public_stage/install.sh" --role client --repo "$repo" \
    --version "$version" --release-dir "$public_stage" --bin-dir "$runtime_work/bin" --config-dir "$config_dir"
  # Publish from the root-owned, archive-verified source, never from a user-writable
  # temporary binary. Initialization and config access above execute without root.
  key_tmp=$(mktemp "$bin_dir/.mlab-gateway.XXXXXXXX")
  install -m 755 "$public_stage/mlab-gateway" "$key_tmp"
  mv -f -- "$key_tmp" "$bin_dir/mlab-gateway"; key_tmp=""
else
  install_args=(--role client --repo "$repo" --version "$version" --release-dir "$stage"
    --bin-dir "$bin_dir" --config-dir "$config_dir")
  if [[ "$service" == user ]]; then install_args+=(--systemd); fi
  bash "$stage/install.sh" "${install_args[@]}"
fi
private_directory "$config_dir" "$runtime_uid"
check_config
key_file "$local_key" '本地 gateway.key' "$runtime_uid"
! keys_equal "$token_source" "$local_key" || die '连接 Token 与新建本地 gateway.key 相同；未启动客户端'
if [[ -e "$server_key" || -L "$server_key" ]]; then
  key_file "$server_key" '已有 server.key' "$runtime_uid"
  keys_equal "$token_source" "$server_key" || die 'server.key 在安装期间发生变化；不会覆盖'
else
  key_tmp=$(mktemp "$config_dir/.server-key.XXXXXXXX")
  install -m 600 "$token_source" "$key_tmp"
  if [[ "$service" == system ]]; then chown "$runtime_uid:$runtime_gid" "$key_tmp"; fi
  if ! ln -- "$key_tmp" "$server_key"; then
    key_file "$server_key" '并发创建的 server.key' "$runtime_uid"
    keys_equal "$token_source" "$server_key" || die 'server.key 被并发创建为不同的密钥；不会覆盖'
  fi
  rm -f -- "$key_tmp"; key_tmp=""
fi
key_file "$server_key" 'server.key' "$runtime_uid"
if "$new_config"; then
  # Only our newly initialized file may change. Existing custom URLs never change.
  existing_url=$(config_string "$config_file" server_url) || die '无法读取新配置的 server_url'
  if [[ "$existing_url" != "$server_url" ]]; then
    original_digest=$(sha256sum "$config_file"); original_digest=${original_digest%% *}
    config_tmp=$(mktemp "$config_dir/.config.XXXXXXXX")
    LC_ALL=C awk -v url="$server_url" '/^[[:space:]]*server_url[[:space:]]*=/ { print "server_url = \"" url "\""; next } { print }' "$config_file" > "$config_tmp"
    chmod 600 "$config_tmp"
    if [[ "$service" == system ]]; then chown "$runtime_uid:$runtime_gid" "$config_tmp"; fi
    current_digest=$(sha256sum "$config_file"); current_digest=${current_digest%% *}
    [[ "$current_digest" == "$original_digest" ]] || die '新配置被并发修改；未更改 server_url'
    mv -- "$config_tmp" "$config_file"; config_tmp=""
  fi
fi
if [[ "$service" == system ]]; then
  if [[ ! -e "$unit_path" && ! -L "$unit_path" ]]; then
    unit_tmp=$(mktemp /etc/systemd/system/.mlab-client-unit.XXXXXXXX)
    cat > "$unit_tmp" <<'UNIT'
[Unit]
Description=mlab gateway client (native WSS connection)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mlab-gateway-client
Group=mlab-gateway-client
WorkingDirectory=/var/lib/mlab-gateway-client
ExecStart="/opt/mlab-gateway-client/bin/mlab-gateway" --config "/var/lib/mlab-gateway-client/config.toml" client serve
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWriteDirectories=/var/lib/mlab-gateway-client

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$unit_tmp"
    # Do not silently replace an independently created unit.
    ln -- "$unit_tmp" "$unit_path" || die 'system unit 被并发创建，未覆盖；请核对后重试'
    rm -f -- "$unit_tmp"; unit_tmp=""
  fi
  check_unit
  systemctl daemon-reload
  systemctl enable mlab-gateway-client.service
  if "$start_service"; then
    systemctl restart mlab-gateway-client.service || die 'system client 服务启动失败；请检查 systemd 日志'
    printf '客户端 system 服务已安装并启动，使用专用非 root 账户。\n'
  else
    printf '客户端已安装；未执行启动或重启：systemctl start mlab-gateway-client\n'
  fi
elif [[ "$service" == user ]]; then
  check_unit
  if "$start_service"; then
    systemctl --user restart mlab-gateway-client.service || die 'client 服务启动失败；请检查用户 systemd 日志'
    printf '客户端已安装并启动；连接 Token 已私密保存。\n'
  else
    printf '客户端已安装；未执行启动或重启：systemctl --user start mlab-gateway-client\n'
  fi
else
  printf '客户端已安装；前台运行：\n'
  printf '%q --config %q client serve\n' "$bin_dir/mlab-gateway" "$config_file"
fi
printf '配置：%s\n本地 API Key 文件：%s\n' "$config_file" "$local_key"
