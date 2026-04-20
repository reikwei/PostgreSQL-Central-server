#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[pg-center-check] $*"
}

die() {
  echo "[pg-center-check][error] $*" >&2
  exit 1
}

usage() {
  cat <<EOF
用法: $0 [host] [port] [interface]

默认值:
  host: 10.66.0.1
  port: 6432
  interface: 自动猜测 wg0
EOF
}

guess_interface() {
  if ip link show wg0 >/dev/null 2>&1; then
    echo wg0
    return 0
  fi

  ip -o link show | awk -F': ' '$2 ~ /^wg/ { print $2; exit }'
}

check_service() {
  local interface_name=$1

  if [[ -n ${interface_name} ]]; then
    systemctl is-active --quiet "wg-quick@${interface_name}" || die "wg-quick@${interface_name} 未运行"
  fi
}

check_route() {
  local host=$1

  ip route get "${host}" >/dev/null 2>&1 || die "无法为 ${host} 找到路由"
}

check_port() {
  local host=$1
  local port=$2
  local attempt

  for attempt in $(seq 1 10); do
    if timeout 3 bash -lc "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      return 0
    fi
    log "第 ${attempt} 次探测 ${host}:${port} 未成功，继续重试"
  done

  return 1
}

show_diagnostics() {
  local host=$1
  local interface_name=$2

  echo
  echo "诊断信息"
  ip route get "${host}" || true
  if [[ -n ${interface_name} ]]; then
    wg show "${interface_name}" || true
    systemctl --no-pager --full status "wg-quick@${interface_name}" || true
  else
    wg show || true
  fi
}

main() {
  local host=${1:-10.66.0.1}
  local port=${2:-6432}
  local interface_name=${3:-}

  if [[ ${host} == "-h" || ${host} == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ -z ${interface_name} ]]; then
    interface_name=$(guess_interface || true)
  fi

  check_service "${interface_name}"
  check_route "${host}"

  if check_port "${host}" "${port}"; then
    log "连通性正常: ${host}:${port}"
    if [[ -n ${interface_name} ]]; then
      log "WireGuard 接口: ${interface_name}"
    fi
    exit 0
  fi

  echo "[pg-center-check][error] 无法连通 ${host}:${port}" >&2
  show_diagnostics "${host}" "${interface_name}"
  exit 1
}

main "$@"