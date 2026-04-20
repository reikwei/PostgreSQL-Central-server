#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${1:-"${SCRIPT_DIR}/.env"}

log() {
  echo "[minio-backup] $*"
}

warn() {
  echo "[minio-backup][warn] $*" >&2
}

die() {
  echo "[minio-backup][error] $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "请使用 sudo 运行此脚本"
  fi
}

require_file() {
  local file_path=$1
  [[ -f "${file_path}" ]] || die "缺少配置文件: ${file_path}"
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

load_env() {
  require_file "${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  MINIO_USER=${MINIO_USER:-minio}
  MINIO_GROUP=${MINIO_GROUP:-minio}
  MINIO_DATA_DIR=${MINIO_DATA_DIR:-/var/lib/minio}
  MINIO_CONFIG_DIR=${MINIO_CONFIG_DIR:-/etc/minio}
  MINIO_API_ADDRESS=${MINIO_API_ADDRESS:-0.0.0.0:9000}
  MINIO_CONSOLE_ADDRESS=${MINIO_CONSOLE_ADDRESS:-127.0.0.1:9001}
  MINIO_SERVER_URL=${MINIO_SERVER_URL:-}
  MINIO_ROOT_USER=${MINIO_ROOT_USER:-minio-root}
  MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-$(openssl rand -hex 20)}

  PGBR_BUCKET=${PGBR_BUCKET:-pgbackrest-prod}
  PGBR_PREFIX=${PGBR_PREFIX:-/pgbackrest}
  PGBR_POLICY_NAME=${PGBR_POLICY_NAME:-pgbackrest-rw}
  MINIO_PGBR_ACCESS_KEY=${MINIO_PGBR_ACCESS_KEY:-pgbackrest}
  MINIO_PGBR_SECRET_KEY=${MINIO_PGBR_SECRET_KEY:-$(openssl rand -hex 20)}

  SSH_PORT=${SSH_PORT:-22}
  ALLOW_SSH_CIDR=${ALLOW_SSH_CIDR:-0.0.0.0/0}
  ALLOW_MINIO_CIDR=${ALLOW_MINIO_CIDR:-}
  ENABLE_UFW=${ENABLE_UFW:-true}

  [[ ${MINIO_DATA_DIR} == /* ]] || die "MINIO_DATA_DIR 必须使用绝对路径"
  [[ ${MINIO_CONFIG_DIR} == /* ]] || die "MINIO_CONFIG_DIR 必须使用绝对路径"
  [[ ${PGBR_PREFIX} == /* ]] || die "PGBR_PREFIX 必须以 / 开头，例如 /pgbackrest"
  [[ ${MINIO_API_ADDRESS} == *:* ]] || die "MINIO_API_ADDRESS 必须形如 10.66.0.2:9000"
  [[ ${MINIO_CONSOLE_ADDRESS} == *:* ]] || die "MINIO_CONSOLE_ADDRESS 必须形如 127.0.0.1:9001"
  [[ -n ${ALLOW_MINIO_CIDR} ]] || die "必须设置 ALLOW_MINIO_CIDR，例如 10.66.0.1/32 或你的主库公网 IP/32"
}

install_packages() {
  log "安装 MinIO 所需软件包"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    ufw
}

install_binaries() {
  log "下载 MinIO 和 mc"
  curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
  chmod 0755 /usr/local/bin/minio

  curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
  chmod 0755 /usr/local/bin/mc
}

create_runtime_user() {
  if ! getent group "${MINIO_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${MINIO_GROUP}"
  fi

  if ! id "${MINIO_USER}" >/dev/null 2>&1; then
    useradd --system \
      --gid "${MINIO_GROUP}" \
      --home-dir "${MINIO_DATA_DIR}" \
      --shell /usr/sbin/nologin \
      "${MINIO_USER}"
  fi
}

write_minio_env() {
  local api_host
  local api_port

  api_host=${MINIO_API_ADDRESS%:*}
  api_port=${MINIO_API_ADDRESS##*:}

  if [[ -z ${MINIO_SERVER_URL} ]]; then
    if [[ ${api_host} == "0.0.0.0" ]]; then
      MINIO_SERVER_URL="http://$(curl -4fsSL https://api.ipify.org || hostname -I | awk '{print $1}'):${api_port}"
    else
      MINIO_SERVER_URL="http://${api_host}:${api_port}"
    fi
  fi

  install -d -m 0750 "${MINIO_CONFIG_DIR}" "${MINIO_DATA_DIR}"
  chown -R "${MINIO_USER}:${MINIO_GROUP}" "${MINIO_CONFIG_DIR}" "${MINIO_DATA_DIR}"

  cat > "${MINIO_CONFIG_DIR}/minio.env" <<EOF
MINIO_VOLUMES=${MINIO_DATA_DIR}
MINIO_OPTS=--address ${MINIO_API_ADDRESS} --console-address ${MINIO_CONSOLE_ADDRESS}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_SERVER_URL=${MINIO_SERVER_URL}
EOF
  chmod 0640 "${MINIO_CONFIG_DIR}/minio.env"
  chown root:"${MINIO_GROUP}" "${MINIO_CONFIG_DIR}/minio.env"
}

write_systemd_unit() {
  log "写入 MinIO systemd 服务"
  cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs/minio/linux/index.html
After=network-online.target
Wants=network-online.target

[Service]
User=${MINIO_USER}
Group=${MINIO_GROUP}
EnvironmentFile=${MINIO_CONFIG_DIR}/minio.env
ExecStart=/usr/local/bin/minio server \
  \\$MINIO_OPTS \
  \\$MINIO_VOLUMES
Restart=always
RestartSec=5
LimitNOFILE=65536
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now minio
}

configure_mc() {
  local api_host
  local api_port
  local local_api_url

  api_host=${MINIO_API_ADDRESS%:*}
  api_port=${MINIO_API_ADDRESS##*:}

  if [[ ${api_host} == "0.0.0.0" ]]; then
    local_api_url="http://127.0.0.1:${api_port}"
  else
    local_api_url="http://${api_host}:${api_port}"
  fi

  log "创建 bucket 和 pgBackRest 专用访问账号"

  mc alias set local "${local_api_url}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
  mc mb --ignore-existing "local/${PGBR_BUCKET}"

  install -d -m 0750 "${MINIO_CONFIG_DIR}/policies"
  cat > "${MINIO_CONFIG_DIR}/policies/pgbackrest.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::${PGBR_BUCKET}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${PGBR_BUCKET}/*"
      ]
    }
  ]
}
EOF

  mc admin policy rm local "${PGBR_POLICY_NAME}" >/dev/null 2>&1 || true
  mc admin policy create local "${PGBR_POLICY_NAME}" "${MINIO_CONFIG_DIR}/policies/pgbackrest.json"

  if mc admin user info local "${MINIO_PGBR_ACCESS_KEY}" >/dev/null 2>&1; then
    warn "MinIO 用户 ${MINIO_PGBR_ACCESS_KEY} 已存在，保留现有用户。若要更换密钥，请手工删除该用户后重跑。"
  else
    mc admin user add local "${MINIO_PGBR_ACCESS_KEY}" "${MINIO_PGBR_SECRET_KEY}"
  fi

  mc admin policy attach local "${PGBR_POLICY_NAME}" --user "${MINIO_PGBR_ACCESS_KEY}"

  cat > /root/minio-pgbackrest-credentials.txt <<EOF
MINIO_SERVER_URL=${MINIO_SERVER_URL}
MINIO_API_ADDRESS=${MINIO_API_ADDRESS}
PGBR_BUCKET=${PGBR_BUCKET}
PGBR_PREFIX=${PGBR_PREFIX}
MINIO_PGBR_ACCESS_KEY=${MINIO_PGBR_ACCESS_KEY}
MINIO_PGBR_SECRET_KEY=${MINIO_PGBR_SECRET_KEY}
EOF
  chmod 0600 /root/minio-pgbackrest-credentials.txt
}

configure_firewall() {
  if [[ ${ENABLE_UFW} != "true" ]]; then
    warn "已跳过 UFW 配置"
    return
  fi

  log "配置 UFW 防火墙"

  if [[ ${ALLOW_SSH_CIDR} == "0.0.0.0/0" ]]; then
    ufw limit "${SSH_PORT}/tcp" comment 'SSH' || true
  else
    ufw allow from "${ALLOW_SSH_CIDR}" to any port "${SSH_PORT}" proto tcp comment 'SSH' || true
  fi

  ufw allow from "${ALLOW_MINIO_CIDR}" to any port "${MINIO_API_ADDRESS##*:}" proto tcp comment 'MinIO API' || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
}

show_summary() {
  cat <<EOF

MinIO 备份节点部署完成。

服务状态
  API: ${MINIO_SERVER_URL}
  Console: ${MINIO_CONSOLE_ADDRESS}
  Bucket: ${PGBR_BUCKET}
  Prefix: ${PGBR_PREFIX}

凭据文件
  /root/minio-pgbackrest-credentials.txt

主库侧需要写入的 pgBackRest 参数
  PGBR_REPO_TYPE=s3
  PGBR_REPO_PATH=${PGBR_PREFIX}
  PGBR_S3_BUCKET=${PGBR_BUCKET}
  PGBR_S3_ENDPOINT=${MINIO_SERVER_URL#http://}
  PGBR_S3_REGION=us-east-1
  PGBR_S3_KEY=${MINIO_PGBR_ACCESS_KEY}
  PGBR_S3_KEY_SECRET=已写入 /root/minio-pgbackrest-credentials.txt
  PGBR_S3_URI_STYLE=path

如果主库通过 WireGuard 访问 MinIO，并且你不打算额外配 TLS
  PGBR_S3_VERIFY_TLS=n

常用命令
  systemctl status minio
  journalctl -u minio -n 100 --no-pager
  mc alias set local ${MINIO_SERVER_URL} ${MINIO_ROOT_USER} '<root-password>'
  mc ls local/${PGBR_BUCKET}
EOF
}

main() {
  require_root
  ensure_os
  load_env
  install_packages
  install_binaries
  create_runtime_user
  write_minio_env
  write_systemd_unit
  configure_mc
  configure_firewall
  show_summary
}

main "$@"