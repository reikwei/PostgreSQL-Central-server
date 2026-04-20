#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/etc/pg-center/pg-center.env

log() {
  echo "[pg-center-peer] $*"
}

die() {
  echo "[pg-center-peer][error] $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "请使用 sudo 运行"
  fi
}

next_client_ip() {
  local used_octets
  used_octets=$(sed -n 's/.*AllowedIPs = [0-9]\+\.[0-9]\+\.[0-9]\+\.\([0-9]\+\)\/32.*/\1/p' "/etc/wireguard/${WG_INTERFACE}.conf" | sort -n)

  for octet in $(seq 2 254); do
    if ! grep -qx "${octet}" <<<"${used_octets}"; then
      echo "${WG_SERVER_IP%.*}.${octet}"
      return 0
    fi
  done

  return 1
}

main() {
  [[ $# -eq 1 ]] || die "用法: $0 peer_name"

  local peer_name=$1
  local client_ip
  local endpoint
  local client_private_key
  local client_public_key
  local client_conf

  require_root
  [[ -f ${ENV_FILE} ]] || die "缺少 ${ENV_FILE}"
  # shellcheck disable=SC1091
  source "${ENV_FILE}"

  [[ ${peer_name} =~ ^[a-zA-Z0-9._-]+$ ]] || die "peer_name 只能包含字母、数字、点、下划线和连字符"

  install -d -m 0700 /etc/wireguard/clients

  if grep -q "# peer: ${peer_name}$" "/etc/wireguard/${WG_INTERFACE}.conf"; then
    die "peer ${peer_name} 已存在"
  fi

  client_ip=$(next_client_ip) || die "可用的客户端地址已经用完"
  endpoint=${PUBLIC_ENDPOINT}

  if [[ -z ${endpoint} ]]; then
    endpoint=$(curl -4fsSL https://api.ipify.org || true)
  fi
  [[ -n ${endpoint} ]] || die "无法确定服务端公网 IP，请先在 ${ENV_FILE} 里设置 PUBLIC_ENDPOINT"

  umask 077
  client_private_key=$(wg genkey)
  client_public_key=$(printf '%s' "${client_private_key}" | wg pubkey)

  cat >> "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF

# peer: ${peer_name}
[Peer]
PublicKey = ${client_public_key}
AllowedIPs = ${client_ip}/32
EOF

  if ! wg show "${WG_INTERFACE}" >/dev/null 2>&1; then
    systemctl start "wg-quick@${WG_INTERFACE}"
  fi

  wg set "${WG_INTERFACE}" peer "${client_public_key}" allowed-ips "${client_ip}/32"

  client_conf=/etc/wireguard/clients/${peer_name}.conf
  cat > "${client_conf}" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ip}/32
DNS = ${WG_CLIENT_DNS}

[Peer]
PublicKey = $(< /etc/wireguard/server_public.key)
AllowedIPs = ${WG_SERVER_IP}/32
Endpoint = ${endpoint}:${WG_PORT}
PersistentKeepalive = 25
EOF

  chmod 0600 "${client_conf}"

  log "客户端配置已生成: ${client_conf}"
  echo
  echo "数据库连接信息"
  echo "  Host: ${WG_SERVER_IP}"
  echo "  Port: ${PGB_PORT}"
  echo "  Database: ${APP_DB_NAME}"
  echo "  Username: ${APP_DB_USER}"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "${client_conf}"
  fi
}

main "$@"