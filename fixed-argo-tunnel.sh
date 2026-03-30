#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
WORK_DIR="/etc/cloudflared"
BIN_PATH="/usr/local/bin/cloudflared"
SERVICE_NAME="cloudflared-fixed"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CONFIG_FILE="${WORK_DIR}/config.yml"
CREDS_FILE="${WORK_DIR}/credentials.json"
TOKEN_FILE="${WORK_DIR}/token"
MODE=""
HOSTNAME=""
SERVICE_URL="http://localhost:8080"
TUNNEL_ID=""
TOKEN=""
VERSION="latest"
EDGE_IP_VERSION="auto"

DEFAULT_MODE="json"
DEFAULT_HOSTNAME="app.example.com"
DEFAULT_SERVICE_URL="http://localhost:8080"
DEFAULT_VERSION="latest"
DEFAULT_CREDS_PATH="./tunnel.json"

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
固定 Argo 隧道安装与运行脚本

直接运行脚本会进入交互菜单：
  sudo ./fixed-argo-tunnel.sh

用法:
  sudo ./fixed-argo-tunnel.sh install --mode token --token <TOKEN> --hostname <sub.example.com> [--service-url http://localhost:8080]
  sudo ./fixed-argo-tunnel.sh install --mode json --credentials /path/to/tunnel.json --hostname <sub.example.com> [--service-url http://localhost:8080]

  sudo ./fixed-argo-tunnel.sh start
  sudo ./fixed-argo-tunnel.sh stop
  sudo ./fixed-argo-tunnel.sh restart
  sudo ./fixed-argo-tunnel.sh status
  sudo ./fixed-argo-tunnel.sh logs
  sudo ./fixed-argo-tunnel.sh run-once
  sudo ./fixed-argo-tunnel.sh uninstall

参数:
  --mode token|json            固定隧道模式
  --token <TOKEN>              Cloudflare Tunnel Token（token 模式必填）
  --credentials <FILE>         tunnel credentials JSON 文件路径（json 模式必填）
  --tunnel-id <UUID>           tunnel ID（json 模式可选，不填则从 credentials 自动提取）
  --hostname <FQDN>            固定隧道域名，如 app.example.com
  --service-url <URL>          回源地址，默认 http://localhost:8080
  --version <latest|x.y.z>     cloudflared 版本，默认 latest
  --edge-ip-version <v>        cloudflared edge-ip-version，默认 auto

示例:
  sudo ./fixed-argo-tunnel.sh install --mode token --token abcdef --hostname app.example.com
  sudo ./fixed-argo-tunnel.sh install --mode json --credentials ./tunnel.json --hostname app.example.com --service-url http://127.0.0.1:3000
EOF
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local input
  read -r -p "$prompt [$default_value]: " input
  if [[ -z "$input" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$input"
  fi
}

read_token_input() {
  echo "提示: Token 输入为可见模式。"
  read -r -p "请输入 Cloudflare Tunnel Token: " TOKEN
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [[ -z "$TOKEN" ]]; then
    err "Token 不能为空"
    return 1
  fi
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行"
    exit 1
  fi
}

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      err "缺少命令: $c"
      exit 1
    }
  done
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    *)
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

download_cloudflared() {
  need_cmd curl sha256sum install
  local arch ver expected_sum tmp_bin release_json download_url digest
  arch="$(detect_arch)"

  if [[ "$VERSION" == "latest" ]]; then
    release_json="$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest)"
    ver="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    [[ -n "$ver" ]] || {
      err "获取最新版本失败"
      exit 1
    }
  else
    ver="$VERSION"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      err "--version 格式应为 x.y.z 或 latest"
      exit 1
    }
    release_json="$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/tags/${ver}")"
  fi

  tmp_bin="$(mktemp)"
  trap "rm -f -- '$tmp_bin'" RETURN

  download_url="$(printf '%s' "$release_json" | sed -n '/"name"[[:space:]]*:[[:space:]]*"cloudflared-linux-'"$arch"'"/,/"browser_download_url"/p' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  digest="$(printf '%s' "$release_json" | sed -n '/"name"[[:space:]]*:[[:space:]]*"cloudflared-linux-'"$arch"'"/,/"browser_download_url"/p' | sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  [[ -n "$download_url" ]] || {
    err "未找到 cloudflared-linux-${arch} 下载地址"
    exit 1
  }

  info "下载 cloudflared ${ver} (${arch})"
  curl -fL --retry 3 --retry-delay 1 -o "$tmp_bin" "$download_url"

  if [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]]; then
    expected_sum="${BASH_REMATCH[1]}"
    echo "${expected_sum}  ${tmp_bin}" | sha256sum -c - >/dev/null
  else
    warn "该版本未提供 digest，跳过 SHA256 校验"
  fi

  install -m 0755 "$tmp_bin" "$BIN_PATH"
  info "已安装: $BIN_PATH"
}

validate_hostname() {
  [[ -n "$HOSTNAME" ]] || {
    err "必须指定 --hostname"
    exit 1
  }
  [[ "$HOSTNAME" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || {
    err "hostname 格式不合法: $HOSTNAME"
    exit 1
  }
}

validate_service_url() {
  [[ "$SERVICE_URL" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]] || {
    err "--service-url 格式不合法: $SERVICE_URL"
    exit 1
  }
}

validate_edge_ip_version() {
  [[ "$EDGE_IP_VERSION" =~ ^(auto|4|6)$ ]] || {
    err "--edge-ip-version 仅支持 auto|4|6"
    exit 1
  }
}

extract_tunnel_id_from_json() {
  local f="$1"
  grep -oE '"TunnelID"\s*:\s*"[0-9a-fA-F-]{36}"' "$f" | head -n1 | cut -d '"' -f4
}

prepare_dirs() {
  install -d -m 0700 "$WORK_DIR"
}

write_config_json_mode() {
  local creds_src="$1"
  [[ -r "$creds_src" ]] || {
    err "credentials 文件不可读: $creds_src"
    exit 1
  }

  if [[ -z "$TUNNEL_ID" ]]; then
    TUNNEL_ID="$(extract_tunnel_id_from_json "$creds_src")"
  fi

  [[ "$TUNNEL_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || {
    err "无法识别 tunnel id，请通过 --tunnel-id 指定"
    exit 1
  }

  install -m 0600 "$creds_src" "$CREDS_FILE"

  cat > "$CONFIG_FILE" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CREDS_FILE}

ingress:
  - hostname: ${HOSTNAME}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF
  chmod 0600 "$CONFIG_FILE"
  info "已生成配置: $CONFIG_FILE"
}

write_token_secret() {
  [[ -n "$TOKEN" ]] || {
    err "token 模式必须传 --token"
    exit 1
  }
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
}

write_service_json_mode() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Fixed Tunnel (JSON credentials)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} tunnel --edge-ip-version ${EDGE_IP_VERSION} --no-autoupdate --config ${CONFIG_FILE} run
Restart=on-failure
RestartSec=5s
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

write_service_token_mode() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Fixed Tunnel (Token)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc '${BIN_PATH} tunnel --edge-ip-version ${EDGE_IP_VERSION} --no-autoupdate run --token "$(cat "$TOKEN_FILE")"'
Restart=on-failure
RestartSec=5s
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0600 "$TOKEN_FILE"
}

enable_service() {
  need_cmd systemctl
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
}

cmd_install() {
  need_root
  download_cloudflared
  prepare_dirs
  validate_hostname
  validate_service_url
  validate_edge_ip_version

  case "$MODE" in
    json)
      [[ -n "${CREDS_SOURCE:-}" ]] || {
        err "json 模式必须提供 --credentials"
        exit 1
      }
      write_config_json_mode "$CREDS_SOURCE"
      write_service_json_mode
      ;;
    token)
      warn "Token 模式会在进程参数中出现 token，生产环境更推荐 JSON credentials 模式。"
      write_token_secret
      write_service_token_mode
      ;;
    *)
      err "--mode 仅支持 token 或 json"
      exit 1
      ;;
  esac

  chmod 0644 "$SERVICE_FILE"
  enable_service
  info "安装完成，服务名: $SERVICE_NAME"
  info "查看状态: systemctl status $SERVICE_NAME"
}

cmd_start() { need_root; systemctl start "$SERVICE_NAME"; }
cmd_stop() { need_root; systemctl stop "$SERVICE_NAME"; }
cmd_restart() { need_root; systemctl restart "$SERVICE_NAME"; }
cmd_status() { systemctl status "$SERVICE_NAME" --no-pager; }
cmd_logs() { journalctl -u "$SERVICE_NAME" -f; }

cmd_run_once() {
  need_root
  [[ -x "$BIN_PATH" ]] || {
    err "未检测到 $BIN_PATH，请先 install"
    exit 1
  }

  if [[ -f "$CONFIG_FILE" ]]; then
    exec "$BIN_PATH" tunnel --edge-ip-version "$EDGE_IP_VERSION" --no-autoupdate --config "$CONFIG_FILE" run
  elif [[ -f "$TOKEN_FILE" ]]; then
    exec "$BIN_PATH" tunnel --edge-ip-version "$EDGE_IP_VERSION" --no-autoupdate run --token "$(cat "$TOKEN_FILE")"
  else
    err "未找到配置文件或 token 文件"
    exit 1
  fi
}

cmd_uninstall() {
  need_root
  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
    systemctl disable --now "$SERVICE_NAME" || true
  fi
  rm -f "$SERVICE_FILE"
  rm -rf "$WORK_DIR"
  if [[ -x "$BIN_PATH" ]]; then
    rm -f "$BIN_PATH"
  fi
  systemctl daemon-reload
  info "已卸载"
}

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="${2:-}"; shift 2 ;;
      --token) TOKEN="${2:-}"; shift 2 ;;
      --credentials) CREDS_SOURCE="${2:-}"; shift 2 ;;
      --tunnel-id) TUNNEL_ID="${2:-}"; shift 2 ;;
      --hostname) HOSTNAME="${2:-}"; shift 2 ;;
      --service-url) SERVICE_URL="${2:-}"; shift 2 ;;
      --version) VERSION="${2:-}"; shift 2 ;;
      --edge-ip-version) EDGE_IP_VERSION="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

install_wizard() {
  need_root
  echo
  echo "====== 固定隧道安装向导 ======"
  echo "1) Token 模式"
  echo "2) JSON 凭据模式（推荐）"

  local mode_choice creds_input
  read -r -p "请选择模式 [1-2] (默认 2): " mode_choice
  mode_choice="${mode_choice:-2}"
  case "$mode_choice" in
    1)
      MODE="token"
      read_token_input
      ;;
    2)
      MODE="json"
      read -r -p "请输入 credentials.json 路径 [${DEFAULT_CREDS_PATH}]: " creds_input
      creds_input="${creds_input:-$DEFAULT_CREDS_PATH}"
      CREDS_SOURCE="$creds_input"
      read -r -p "请输入 Tunnel ID（可回车自动从 JSON 提取）: " TUNNEL_ID
      ;;
    *)
      err "无效选项"
      return 1
      ;;
  esac

  HOSTNAME="$(prompt_default '请输入固定隧道域名(可改,回车用默认)' "$DEFAULT_HOSTNAME")"
  SERVICE_URL="$(prompt_default '请输入回源地址(可改,回车用默认)' "$DEFAULT_SERVICE_URL")"
  VERSION="$(prompt_default '请输入 cloudflared 版本(可改,回车用默认)' "$DEFAULT_VERSION")"
  EDGE_IP_VERSION="$(prompt_default '请输入 edge-ip-version(可改,回车用默认)' 'auto')"

  cmd_install
}

interactive_menu() {
  while true; do
    echo
    echo "====== Cloudflare 固定隧道管理 ======"
    echo "1) 安装固定隧道"
    echo "2) 启动服务"
    echo "3) 停止服务"
    echo "4) 重启服务"
    echo "5) 查看状态"
    echo "6) 查看日志"
    echo "7) 前台运行(run-once)"
    echo "8) 卸载"
    echo "0) 退出"

    local choice
    read -r -p "请选择 [0-8]: " choice
    case "$choice" in
      1) install_wizard ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_run_once ;;
      8)
        read -r -p "确认卸载? [y/N]: " choice
        if [[ "${choice,,}" == "y" ]]; then
          cmd_uninstall
        fi
        ;;
      0) exit 0 ;;
      *) warn "无效选项，请重试" ;;
    esac
  done
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install)
      shift
      parse_install_args "$@"
      cmd_install
      ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    run-once) cmd_run_once ;;
    uninstall) cmd_uninstall ;;
    -h|--help|help)
      usage
      ;;
    "")
      interactive_menu
      ;;
    *)
      err "未知命令: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
