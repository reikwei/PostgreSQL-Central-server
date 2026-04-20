#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

log() {
  echo "[wg-client] $*"
}

die() {
  echo "[wg-client][error] $*" >&2
  exit 1
}

validate_mtu() {
  local mtu_value=$1

  [[ ${mtu_value} =~ ^[0-9]+$ ]] || die "WG_MTU 必须是数字"

  if (( mtu_value < 1280 || mtu_value > 1500 )); then
    die "WG_MTU 必须位于 1280 到 1500 之间，跨地域链路建议使用 1280 或 1380"
  fi
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "请使用 sudo 运行"
  fi
}

ensure_os() {
  . /etc/os-release
  case "${ID}" in
    ubuntu|debian)
      ;;
    *)
      die "当前脚本只支持 Ubuntu 或 Debian，检测到: ${ID}"
      ;;
  esac
}

install_packages() {
  log "安装 WireGuard 客户端依赖"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iproute2 \
    systemd \
    wireguard \
    resolvconf
}

install_helper_scripts() {
  local connectivity_script="${SCRIPT_DIR}/check-pg-center-connectivity.sh"

  if [[ -f ${connectivity_script} ]]; then
    install -m 0755 "${connectivity_script}" /usr/local/sbin/pg-center-check-connectivity
    log "已安装连通性检查脚本 /usr/local/sbin/pg-center-check-connectivity"
  else
    log "未找到 ${connectivity_script}，跳过安装连通性检查脚本"
  fi
}

validate_config() {
  local config_path=$1

  [[ -f ${config_path} ]] || die "配置文件不存在: ${config_path}"
  grep -q '^\[Interface\]$' "${config_path}" || die "配置文件缺少 [Interface] 段"
  grep -q '^\[Peer\]$' "${config_path}" || die "配置文件缺少 [Peer] 段"
  grep -q '^PrivateKey = ' "${config_path}" || die "配置文件缺少 PrivateKey"
  grep -q '^PublicKey = ' "${config_path}" || die "配置文件缺少 Peer PublicKey"
  grep -q '^Endpoint = ' "${config_path}" || die "配置文件缺少 Endpoint"
}

install_client_config() {
  local source_config=$1
  local interface_name=$2
  local target_config="/etc/wireguard/${interface_name}.conf"
  local client_mtu=${WG_MTU:-1380}

  install -d -m 0700 /etc/wireguard
  validate_mtu "${client_mtu}"

  if [[ -f ${target_config} ]]; then
    cp -a "${target_config}" "${target_config}.bak.$(date +%F-%H%M%S)"
  fi

  install -m 0600 "${source_config}" "${target_config}"

  if ! grep -q '^MTU = ' "${target_config}"; then
    awk -v mtu="${client_mtu}" '
      BEGIN { inserted = 0 }
      /^Address = / && !inserted {
        print
        print "MTU = " mtu
        inserted = 1
        next
      }
      /^\[Peer\]$/ && !inserted {
        print "MTU = " mtu
        inserted = 1
      }
      { print }
      END {
        if (!inserted) {
          print "MTU = " mtu
        }
      }
    ' "${target_config}" > "${target_config}.tmp"
    mv "${target_config}.tmp" "${target_config}"
    chmod 0600 "${target_config}"
    log "客户端配置缺少 MTU，已自动补充 MTU = ${client_mtu}"
  fi

  log "客户端配置已写入 ${target_config}"
}

enable_client() {
  local interface_name=$1
  local service_name="wg-quick@${interface_name}"

  systemctl enable "${service_name}"

  if systemctl is-active --quiet "${service_name}"; then
    systemctl restart "${service_name}"
  else
    systemctl start "${service_name}"
  fi
}

run_connectivity_check() {
  local interface_name=$1

  if [[ -x /usr/local/sbin/pg-center-check-connectivity ]]; then
    /usr/local/sbin/pg-center-check-connectivity 10.66.0.1 6432 "${interface_name}"
  else
    log "未安装 pg-center-check-connectivity，跳过自动连通性测试"
  fi
}

show_summary() {
  local interface_name=$1

  cat <<EOF

WireGuard 客户端安装完成。

服务
  systemctl status wg-quick@${interface_name}

常用命令
  wg show ${interface_name}
  systemctl restart wg-quick@${interface_name}
  systemctl stop wg-quick@${interface_name}
  /usr/local/sbin/pg-center-check-connectivity 10.66.0.1 6432 ${interface_name}

下一步
  1. 在本机执行 wg show ${interface_name}，确认握手正常。
  2. 如果刚才自动检查失败，再手工执行 /usr/local/sbin/pg-center-check-connectivity 10.66.0.1 6432 ${interface_name}。
EOF
}

main() {
  local source_config=${1:-}
  local interface_name=${2:-}

  [[ -n ${source_config} ]] || die "用法: $0 /path/to/client.conf [interface_name]"

  require_root
  ensure_os
  validate_config "${source_config}"

  if [[ -z ${interface_name} ]]; then
    interface_name=$(basename "${source_config}")
    interface_name=${interface_name%.conf}
  fi

  [[ ${interface_name} =~ ^[a-zA-Z0-9._-]+$ ]] || die "interface_name 只能包含字母、数字、点、下划线和连字符"

  install_packages
  install_helper_scripts
  install_client_config "${source_config}" "${interface_name}"
  enable_client "${interface_name}"
  run_connectivity_check "${interface_name}"
  show_summary "${interface_name}"
}

main "$@"