#!/usr/bin/env bash
# Install a checksum-verified Linux release. Never overwrite configuration or OAuth credentials.
set -euo pipefail
umask 077

repo="m9rco/mlab-gateway-client"
version="v0.4.3"
role="client"
bin_dir="${HOME}/.local/bin"
config_dir=""
release_dir=""
use_systemd=false
download_mode="curl"
stage=""
binary_tmp=""
unit_tmp=""

die() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
cleanup() {
  [[ -z "$stage" ]] || rm -rf -- "$stage"
  [[ -z "$binary_tmp" ]] || rm -f -- "$binary_tmp"
  [[ -z "$unit_tmp" ]] || rm -f -- "$unit_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<'USAGE'
Usage: bash install.sh [options]
  --version v0.4.3       Release tag (default: v0.4.3)
  --role server|client  Deployment role (default: client)
  --repo OWNER/REPO      Release repository
  --bin-dir PATH         Binary destination (default: ~/.local/bin)
  --config-dir PATH      Configuration destination (role-specific default)
  --systemd              Create and enable a user unit; does not start the service
  --download auto|gh|curl  auto prefers authenticated gh; curl requires a public repo
  --release-dir PATH     Use previously downloaded archive and SHA256SUMS (offline)
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--role|--repo|--bin-dir|--config-dir|--release-dir|--download)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 缺少值"
      option="$1"; value="$2"; shift 2
      case "$option" in
        --version) version="$value" ;;
        --role) role="$value" ;;
        --repo) repo="$value" ;;
        --bin-dir) bin_dir="$value" ;;
        --config-dir) config_dir="$value" ;;
        --release-dir) release_dir="$value" ;;
        --download) download_mode="$value" ;;
      esac ;;
    --systemd) use_systemd=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "仓库格式必须是 OWNER/REPO"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || die "版本必须是 v 开头的 release tag"
[[ "$download_mode" == auto || "$download_mode" == gh || "$download_mode" == curl ]] || die "无效 download 模式"
[[ "$role" == server || "$role" == client ]] || die "role 必须是 server 或 client"
if [[ -z "$config_dir" ]]; then
  if [[ "$role" == server ]]; then
    config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/mlab-gateway"
  else
    config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/mlab-gateway-client"
  fi
fi
[[ "$(uname -s)" == Linux ]] || die "预编译安装仅支持 Linux；其他平台请 cargo build --release"
case "$(uname -m)" in
  x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
  *) die "不支持架构：$(uname -m)" ;;
esac
for command in tar awk mktemp install sha256sum tr stat; do
  command -v "$command" >/dev/null || die "缺少依赖：$command"
done
for path in "$bin_dir" "$config_dir"; do
  [[ "$path" == /* ]] || die "安装目录必须是绝对路径"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || die "目录不能包含换行或制表符"
done
# Normalize trailing slashes so a symlink cannot hide behind a directory suffix.
while [[ "$config_dir" != / && "$config_dir" == */ ]]; do config_dir=${config_dir%/}; done
check_private_directory() {
  local path="$1" mode
  [[ ! -L "$path" ]] || die "配置目录不能是符号链接：$path"
  [[ -d "$path" ]] || die "配置目录必须是目录：$path"
  [[ -O "$path" ]] || die "配置目录必须由当前用户拥有：$path"
  # GNU stat is used on Linux; BSD stat also permits offline tests on macOS.
  if ! mode=$(stat -c '%a' -- "$path" 2>/dev/null); then
    mode=$(stat -f '%Lp' "$path") || die "无法检查配置目录权限：$path"
  fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "无法读取配置目录权限：$path"
  (( (8#$mode & 077) == 0 )) || die "已有配置目录必须为私有权限（建议 0700）；安装器不会修改其权限：$path"
}
if [[ -e "$config_dir" || -L "$config_dir" ]]; then
  check_private_directory "$config_dir"
fi
if "$use_systemd"; then
  command -v systemctl >/dev/null || die "--systemd 需要 systemctl"
  systemctl --user show-environment >/dev/null 2>&1 || die "用户 systemd 会话不可用；使用普通安装或先配置 user manager"
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/mlab-gateway-install.XXXXXXXX")
archive="mlab-gateway-${version}-${target}.tar.gz"
if [[ -n "$release_dir" ]]; then
  [[ -f "$release_dir/$archive" && -f "$release_dir/SHA256SUMS" ]] || die "离线目录缺少 $archive 或 SHA256SUMS"
  cp -- "$release_dir/$archive" "$release_dir/SHA256SUMS" "$stage/"
else
  if [[ "$download_mode" == auto ]]; then
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then download_mode=gh; else download_mode=curl; fi
  fi
  if [[ "$download_mode" == gh ]]; then
    command -v gh >/dev/null || die "私有仓库下载需要 GitHub CLI；先运行 gh auth login"
    gh release download "$version" --repo "$repo" --pattern "$archive" --pattern SHA256SUMS --dir "$stage" || die "release 下载失败；确认 gh 已登录且有仓库权限"
  else
    command -v curl >/dev/null || die "缺少 curl"
    for asset in "$archive" SHA256SUMS; do
      curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
        "https://github.com/${repo}/releases/download/${version}/${asset}" --output "$stage/$asset" || die "下载失败；私有仓库请使用 --download gh"
    done
  fi
fi

# Select one exact manifest entry; do not ask sha256sum to read paths supplied by the manifest.
expected=$(awk -v wanted="$archive" '$2 == wanted || $2 == "*" wanted { print $1 }' "$stage/SHA256SUMS")
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "校验清单必须包含且仅包含一个对应 SHA-256"
actual=$(sha256sum "$stage/$archive")
actual=${actual%% *}
expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
[[ "$actual" == "$expected" ]] || die "SHA-256 校验失败；二进制未安装"

# Releases contain one regular file. Stream extraction avoids creating archive-supplied paths.
entries=$(tar -tzf "$stage/$archive") || die "无法读取 tar.gz"
[[ "$entries" == mlab-gateway ]] || die "归档包含意外路径；拒绝解压"
details=$(tar -tvzf "$stage/$archive") || die "无法读取归档类型"
[[ "${details:0:1}" == '-' ]] || die "归档中的二进制必须是普通文件"
tar -xOzf "$stage/$archive" -- mlab-gateway > "$stage/mlab-gateway"
[[ -s "$stage/mlab-gateway" ]] || die "二进制为空"
chmod 700 "$stage/mlab-gateway"
"$stage/mlab-gateway" --version

mkdir -p -- "$bin_dir"
if [[ ! -e "$config_dir" && ! -L "$config_dir" ]]; then
  # The process umask is 077, so every newly created directory is 0700.
  mkdir -p -- "$config_dir"
fi
# Recheck after creation; never chmod an existing directory such as /etc.
check_private_directory "$config_dir"
[[ ! -L "$config_dir/config.toml" ]] || die "config.toml 不能是符号链接"
if [[ ! -e "$config_dir/config.toml" ]]; then
  "$stage/mlab-gateway" --config "$config_dir/config.toml" "$role" init
else
  printf '保留已有配置和凭据：%s\n' "$config_dir/config.toml"
  if [[ "$role" == client ]] && awk '/^[[:space:]]*(ssh_target|ssh_port|ssh_identity_file|server_port|relay_url|managed_ssh)[[:space:]]*=/ { found=1 } END { exit !found }' "$config_dir/config.toml"; then
    printf '检测到旧版 SSH client 配置；请先备份 config.toml，再运行 client init 生成 WSS 配置。已有 Key 保留。\n'
  fi
fi
binary_tmp=$(mktemp "$bin_dir/.mlab-gateway.XXXXXXXX")
install -m 755 "$stage/mlab-gateway" "$binary_tmp"
mv -f -- "$binary_tmp" "$bin_dir/mlab-gateway"
binary_tmp=""

if "$use_systemd"; then
  unit_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
  mkdir -p -- "$unit_dir"
  unit_name="mlab-gateway-${role}.service"
  unit_path="$unit_dir/$unit_name"
  [[ ! -L "$unit_path" ]] || die "systemd unit 不能是符号链接"
  if [[ ! -e "$unit_path" ]]; then
    # systemd quoted values need escaping independently of shell quoting.
    escape_unit() { local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//%/%%}; printf '%s' "$s"; }
    unit_binary=$(escape_unit "$bin_dir/mlab-gateway")
    unit_config=$(escape_unit "$config_dir/config.toml")
    unit_tmp=$(mktemp "$unit_dir/.mlab-gateway-unit.XXXXXXXX")
    cat > "$unit_tmp" <<UNIT
[Unit]
Description=mlab subscription gateway $role
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$unit_binary" --config "$unit_config" $role serve
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
RestrictSUIDSGID=true

[Install]
WantedBy=default.target
UNIT
    chmod 600 "$unit_tmp"
    mv -- "$unit_tmp" "$unit_path"
    unit_tmp=""
  else
    printf '保留已有 systemd unit：%s\n' "$unit_path"
  fi
  systemctl --user daemon-reload
  systemctl --user enable "$unit_name"
  printf '完成 %s 配置后启动：systemctl --user start %s\n' "$role" "${unit_name%.service}"
fi
printf '已安装 %s（%s）：%s/mlab-gateway\n配置：%s/config.toml\n' "$version" "$role" "$bin_dir" "$config_dir"
if [[ "$role" == server ]]; then
  printf '登录：%q --config %q server login --mode siwc --credentials %q\n' "$bin_dir/mlab-gateway" "$config_dir/config.toml" "$config_dir/credentials.json"
  if [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/mlab-gateway.service" ]]; then
    printf '检测到 v0.1 unit；切换前停止它：systemctl --user disable --now mlab-gateway\n'
  fi
else
  printf '请配置管理员提供的 WSS server_url 与连接 Token；client 无需 OAuth 凭据或 SSH 运行时。\n'
fi
printf '运行：%q --config %q %s serve\n' "$bin_dir/mlab-gateway" "$config_dir/config.toml" "$role"
