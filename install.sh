#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=${1:-"${SCRIPT_DIR}/.env"}

log() {
  echo "[pg-center] $*"
}

warn() {
  echo "[pg-center][warn] $*" >&2
}

die() {
  echo "[pg-center][error] $*" >&2
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

validate_identifier() {
  local value=$1
  local field_name=$2
  [[ ${value} =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "${field_name} 只能包含字母、数字和下划线，且不能以数字开头"
}

install_pgdg_repo_if_needed() {
  if apt-cache show "postgresql-${PG_MAJOR}" >/dev/null 2>&1; then
    return
  fi

  log "默认软件源没有 postgresql-${PG_MAJOR}，正在添加 PGDG 软件源"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg
  chmod 0644 /etc/apt/keyrings/pgdg.gpg

  . /etc/os-release
  echo "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
  apt-get update
}

load_env() {
  require_file "${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  PG_MAJOR=${PG_MAJOR:-16}
  PG_CLUSTER=${PG_CLUSTER:-main}
  PG_PORT=${PG_PORT:-5432}
  PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS:-200}
  PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS:-auto}
  PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE:-auto}
  PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM:-auto}
  PG_WAL_BUFFERS=${PG_WAL_BUFFERS:-16MB}
  PG_CHECKPOINT_TIMEOUT=${PG_CHECKPOINT_TIMEOUT:-15min}
  PG_MAX_WAL_SIZE=${PG_MAX_WAL_SIZE:-4GB}
  PG_MIN_WAL_SIZE=${PG_MIN_WAL_SIZE:-1GB}
  PG_SYNCHRONOUS_COMMIT=${PG_SYNCHRONOUS_COMMIT:-off}

  APP_DB_NAME=${APP_DB_NAME:-robot_center}
  APP_DB_USER=${APP_DB_USER:-robot_app}
  APP_DB_PASSWORD=${APP_DB_PASSWORD:-$(openssl rand -hex 24)}

  PGB_PORT=${PGB_PORT:-6432}
  PGB_POOL_MODE=${PGB_POOL_MODE:-transaction}
  PGB_MAX_CLIENT_CONN=${PGB_MAX_CLIENT_CONN:-5000}
  PGB_DEFAULT_POOL_SIZE=${PGB_DEFAULT_POOL_SIZE:-40}
  PGB_MIN_POOL_SIZE=${PGB_MIN_POOL_SIZE:-10}
  PGB_RESERVE_POOL_SIZE=${PGB_RESERVE_POOL_SIZE:-10}
  PGB_MAX_DB_CONNECTIONS=${PGB_MAX_DB_CONNECTIONS:-80}
  PGB_MAX_USER_CONNECTIONS=${PGB_MAX_USER_CONNECTIONS:-80}

  WG_INTERFACE=${WG_INTERFACE:-wg0}
  WG_PORT=${WG_PORT:-51820}
  WG_MTU=${WG_MTU:-1380}
  WG_SUBNET=${WG_SUBNET:-10.66.0.0/24}
  WG_SERVER_IP=${WG_SERVER_IP:-10.66.0.1}
  WG_CLIENT_DNS=${WG_CLIENT_DNS:-1.1.1.1}
  PUBLIC_ENDPOINT=${PUBLIC_ENDPOINT:-}

  SSH_PORT=${SSH_PORT:-22}
  ALLOW_SSH_CIDR=${ALLOW_SSH_CIDR:-0.0.0.0/0}
  ENABLE_UFW=${ENABLE_UFW:-true}

  PGBR_STANZA=${PGBR_STANZA:-pgcenter}
  PGBR_REPO_TYPE=${PGBR_REPO_TYPE:-local}
  PGBR_REPO_PATH=${PGBR_REPO_PATH:-/var/lib/pgbackrest}
  PGBR_PROCESS_MAX=${PGBR_PROCESS_MAX:-2}
  PGBR_COMPRESS_TYPE=${PGBR_COMPRESS_TYPE:-zst}
  PGBR_ARCHIVE_ASYNC=${PGBR_ARCHIVE_ASYNC:-y}
  PGBR_START_FAST=${PGBR_START_FAST:-y}
  PGBR_DELTA=${PGBR_DELTA:-y}
  PGBR_RETENTION_FULL=${PGBR_RETENTION_FULL:-2}
  PGBR_RETENTION_DIFF=${PGBR_RETENTION_DIFF:-6}
  PGBR_FULL_ONCALENDAR=${PGBR_FULL_ONCALENDAR:-Sun *-*-* 03:20:00}
  PGBR_INCR_ONCALENDAR=${PGBR_INCR_ONCALENDAR:-Mon..Sat *-*-* 03:20:00}

  PGBR_S3_BUCKET=${PGBR_S3_BUCKET:-}
  PGBR_S3_ENDPOINT=${PGBR_S3_ENDPOINT:-}
  PGBR_S3_REGION=${PGBR_S3_REGION:-}
  PGBR_S3_KEY=${PGBR_S3_KEY:-}
  PGBR_S3_KEY_SECRET=${PGBR_S3_KEY_SECRET:-}
  PGBR_S3_URI_STYLE=${PGBR_S3_URI_STYLE:-path}
  PGBR_S3_VERIFY_TLS=${PGBR_S3_VERIFY_TLS:-y}

  validate_identifier "${APP_DB_NAME}" "APP_DB_NAME"
  validate_identifier "${APP_DB_USER}" "APP_DB_USER"
  validate_identifier "${PGBR_STANZA}" "PGBR_STANZA"

  if [[ ${PGB_POOL_MODE} != "transaction" && ${PGB_POOL_MODE} != "session" ]]; then
    die "PGB_POOL_MODE 仅支持 transaction 或 session"
  fi

  if [[ ${PGBR_REPO_TYPE} != "local" && ${PGBR_REPO_TYPE} != "s3" ]]; then
    die "PGBR_REPO_TYPE 仅支持 local 或 s3"
  fi

  [[ ${WG_SUBNET} =~ ^([0-9]{1,3}\.){3}0/24$ ]] || die "当前脚本要求 WG_SUBNET 使用 /24 网段，例如 10.66.0.0/24"
  [[ ${WG_SERVER_IP} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "WG_SERVER_IP 格式不正确"
  [[ ${WG_MTU} =~ ^[0-9]+$ ]] || die "WG_MTU 必须是数字"

  if [[ ${WG_SERVER_IP%.*}.0/24 != ${WG_SUBNET} ]]; then
    die "WG_SERVER_IP 与 WG_SUBNET 不匹配"
  fi

  if (( WG_MTU < 1280 || WG_MTU > 1500 )); then
    die "WG_MTU 必须位于 1280 到 1500 之间，跨地域链路建议使用 1280 或 1380"
  fi

  if [[ ${PGBR_REPO_PATH} != /* ]]; then
    die "PGBR_REPO_PATH 必须使用绝对路径"
  fi

  if [[ ${PGBR_REPO_TYPE} == "s3" ]]; then
    [[ -n ${PGBR_S3_BUCKET} ]] || die "使用 s3 仓库时必须设置 PGBR_S3_BUCKET"
    [[ -n ${PGBR_S3_ENDPOINT} ]] || die "使用 s3 仓库时必须设置 PGBR_S3_ENDPOINT"
    [[ -n ${PGBR_S3_REGION} ]] || die "使用 s3 仓库时必须设置 PGBR_S3_REGION"
    [[ -n ${PGBR_S3_KEY} ]] || die "使用 s3 仓库时必须设置 PGBR_S3_KEY"
    [[ -n ${PGBR_S3_KEY_SECRET} ]] || die "使用 s3 仓库时必须设置 PGBR_S3_KEY_SECRET"
  fi

  if [[ -z ${PUBLIC_ENDPOINT} ]]; then
    PUBLIC_ENDPOINT=$(curl -4fsSL https://api.ipify.org || true)
  fi

  if [[ -z ${PUBLIC_ENDPOINT} ]]; then
    warn "未能自动探测 PUBLIC_ENDPOINT，后续生成客户端配置时请手工填写"
  fi
}

calculate_auto_tuning() {
  local mem_mb
  mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)

  if [[ ${PG_SHARED_BUFFERS} == "auto" ]]; then
    if (( mem_mb >= 8192 )); then
      PG_SHARED_BUFFERS=2GB
    elif (( mem_mb >= 4096 )); then
      PG_SHARED_BUFFERS=1GB
    elif (( mem_mb >= 2048 )); then
      PG_SHARED_BUFFERS=512MB
    else
      PG_SHARED_BUFFERS=256MB
    fi
  fi

  if [[ ${PG_EFFECTIVE_CACHE_SIZE} == "auto" ]]; then
    if (( mem_mb >= 8192 )); then
      PG_EFFECTIVE_CACHE_SIZE=6GB
    elif (( mem_mb >= 4096 )); then
      PG_EFFECTIVE_CACHE_SIZE=3GB
    elif (( mem_mb >= 2048 )); then
      PG_EFFECTIVE_CACHE_SIZE=1536MB
    else
      PG_EFFECTIVE_CACHE_SIZE=768MB
    fi
  fi

  if [[ ${PG_MAINTENANCE_WORK_MEM} == "auto" ]]; then
    if (( mem_mb >= 8192 )); then
      PG_MAINTENANCE_WORK_MEM=512MB
    else
      PG_MAINTENANCE_WORK_MEM=256MB
    fi
  fi
}

ensure_os() {
  require_file /etc/os-release
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
  log "安装基础软件包"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    openssl \
    postgresql-common \
    qrencode \
    ufw \
    wireguard

  install_pgdg_repo_if_needed

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "postgresql-${PG_MAJOR}" \
    "postgresql-client-${PG_MAJOR}" \
    pgbouncer \
    pgbackrest
}

ensure_pg_cluster() {
  if ! pg_lsclusters | awk -v version="${PG_MAJOR}" -v cluster="${PG_CLUSTER}" '$1 == version && $2 == cluster { found = 1 } END { exit found ? 0 : 1 }'; then
    log "创建 PostgreSQL 集群 ${PG_MAJOR}/${PG_CLUSTER}"
    pg_createcluster "${PG_MAJOR}" "${PG_CLUSTER}"
  fi
}

postgresql_conf_dir() {
  echo "/etc/postgresql/${PG_MAJOR}/${PG_CLUSTER}"
}

pg_data_dir() {
  echo "/var/lib/postgresql/${PG_MAJOR}/${PG_CLUSTER}"
}

configure_postgresql() {
  local conf_dir
  conf_dir=$(postgresql_conf_dir)

  install -d -m 0755 "${conf_dir}/conf.d"

  log "写入 PostgreSQL 调优配置"
  cat > "${conf_dir}/conf.d/90-pg-center.conf" <<EOF
listen_addresses = '127.0.0.1'
port = ${PG_PORT}
max_connections = ${PG_MAX_CONNECTIONS}
shared_buffers = '${PG_SHARED_BUFFERS}'
effective_cache_size = '${PG_EFFECTIVE_CACHE_SIZE}'
maintenance_work_mem = '${PG_MAINTENANCE_WORK_MEM}'
wal_buffers = '${PG_WAL_BUFFERS}'
checkpoint_timeout = '${PG_CHECKPOINT_TIMEOUT}'
checkpoint_completion_target = 0.9
max_wal_size = '${PG_MAX_WAL_SIZE}'
min_wal_size = '${PG_MIN_WAL_SIZE}'
synchronous_commit = ${PG_SYNCHRONOUS_COMMIT}
password_encryption = 'scram-sha-256'
wal_level = replica
archive_mode = on
archive_timeout = 60
archive_command = 'pgbackrest --stanza=${PGBR_STANZA} archive-push %p'
restore_command = 'pgbackrest --stanza=${PGBR_STANZA} archive-get %f "%p"'
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 10
log_checkpoints = on
log_connections = on
log_disconnections = on
EOF

  log "写入 PostgreSQL 访问控制规则"
  awk '
    BEGIN { skip = 0 }
    /^# BEGIN PG-CENTER MANAGED BLOCK$/ { skip = 1; next }
    /^# END PG-CENTER MANAGED BLOCK$/ { skip = 0; next }
    skip == 0 { print }
  ' "${conf_dir}/pg_hba.conf" > "${conf_dir}/pg_hba.conf.tmp"

  cat >> "${conf_dir}/pg_hba.conf.tmp" <<EOF

# BEGIN PG-CENTER MANAGED BLOCK
host    all              all              127.0.0.1/32    scram-sha-256
host    all              all              ::1/128         scram-sha-256
# END PG-CENTER MANAGED BLOCK
EOF
  mv "${conf_dir}/pg_hba.conf.tmp" "${conf_dir}/pg_hba.conf"

  systemctl enable "postgresql@${PG_MAJOR}-${PG_CLUSTER}"
  systemctl restart "postgresql@${PG_MAJOR}-${PG_CLUSTER}"
}

create_database_and_user() {
  log "创建或更新业务数据库和账号"

  if runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname = '${APP_DB_USER}'" postgres | grep -qx '1'; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 postgres -c "ALTER ROLE \"${APP_DB_USER}\" WITH LOGIN PASSWORD '${APP_DB_PASSWORD}'"
  else
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 postgres -c "CREATE ROLE \"${APP_DB_USER}\" LOGIN PASSWORD '${APP_DB_PASSWORD}'"
  fi

  if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname = '${APP_DB_NAME}'" postgres | grep -qx '1'; then
    runuser -u postgres -- createdb -O "${APP_DB_USER}" "${APP_DB_NAME}"
  fi

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 postgres <<EOF
ALTER DATABASE "${APP_DB_NAME}" OWNER TO "${APP_DB_USER}";
GRANT ALL PRIVILEGES ON DATABASE "${APP_DB_NAME}" TO "${APP_DB_USER}";
EOF
}

configure_pgbouncer() {
  local role_secret
  local pgbouncer_runtime_user
  local pgbouncer_runtime_group

  role_secret=$(runuser -u postgres -- psql -Atqc "SELECT rolpassword FROM pg_authid WHERE rolname = '${APP_DB_USER}'")
  [[ -n ${role_secret} ]] || die "未能读取 ${APP_DB_USER} 的 SCRAM 密钥"

  log "写入 PgBouncer 配置"
  cat > /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=127.0.0.1 port=${PG_PORT} pool_size=${PGB_DEFAULT_POOL_SIZE} reserve_pool=${PGB_RESERVE_POOL_SIZE}

[pgbouncer]
listen_addr = ${WG_SERVER_IP}
listen_port = ${PGB_PORT}
unix_socket_dir = /var/run/postgresql
pidfile = /run/postgresql/pgbouncer.pid
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = ${PGB_POOL_MODE}
max_client_conn = ${PGB_MAX_CLIENT_CONN}
default_pool_size = ${PGB_DEFAULT_POOL_SIZE}
min_pool_size = ${PGB_MIN_POOL_SIZE}
reserve_pool_size = ${PGB_RESERVE_POOL_SIZE}
max_db_connections = ${PGB_MAX_DB_CONNECTIONS}
max_user_connections = ${PGB_MAX_USER_CONNECTIONS}
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits,options
server_tls_sslmode = disable
client_tls_sslmode = disable
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
stats_period = 60
EOF

  printf '"%s" "%s"\n' "${APP_DB_USER}" "${role_secret}" > /etc/pgbouncer/userlist.txt

  pgbouncer_runtime_user=$(systemctl show -p User --value pgbouncer 2>/dev/null || true)
  pgbouncer_runtime_group=$(systemctl show -p Group --value pgbouncer 2>/dev/null || true)
  pgbouncer_runtime_user=${pgbouncer_runtime_user:-pgbouncer}
  pgbouncer_runtime_group=${pgbouncer_runtime_group:-${pgbouncer_runtime_user}}

  if getent group "${pgbouncer_runtime_group}" >/dev/null 2>&1; then
    chown root:"${pgbouncer_runtime_group}" /etc/pgbouncer/userlist.txt /etc/pgbouncer/pgbouncer.ini
    chmod 0640 /etc/pgbouncer/userlist.txt /etc/pgbouncer/pgbouncer.ini
  else
    chmod 0644 /etc/pgbouncer/pgbouncer.ini
    chmod 0600 /etc/pgbouncer/userlist.txt
  fi

  if [[ -f /etc/default/pgbouncer ]]; then
    sed -i 's/^START=.*/START=1/' /etc/default/pgbouncer
  fi

  install -d -m 0755 /etc/systemd/system/pgbouncer.service.d
  cat > /etc/systemd/system/pgbouncer.service.d/override.conf <<EOF
[Unit]
Requires=wg-quick@${WG_INTERFACE}.service
After=wg-quick@${WG_INTERFACE}.service

[Service]
Restart=on-failure
RestartSec=2s
EOF

  systemctl daemon-reload
  systemctl enable pgbouncer
  systemctl restart pgbouncer
}

install_management_script() {
  if [[ -f "${SCRIPT_DIR}/pg-center-admin.sh" ]]; then
    install -m 0755 "${SCRIPT_DIR}/pg-center-admin.sh" /usr/local/sbin/pg-center-admin

    cat > /usr/local/bin/pgadmin <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 ]]; then
  exec /usr/local/sbin/pg-center-admin "$@"
fi

exec sudo /usr/local/sbin/pg-center-admin "$@"
EOF
    chmod 0755 /usr/local/bin/pgadmin
  fi
}

configure_pgbackrest() {
  local data_dir
  local global_repo_lines

  data_dir=$(pg_data_dir)

  log "配置 pgBackRest"

  install -d -m 0750 /etc/pgbackrest
  chown root:postgres /etc/pgbackrest
  install -d -m 0750 /var/log/pgbackrest /var/spool/pgbackrest
  chown postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest

  if [[ ${PGBR_REPO_TYPE} == "local" ]]; then
    install -d -m 0750 "${PGBR_REPO_PATH}"
    chown postgres:postgres "${PGBR_REPO_PATH}"
    global_repo_lines=$(cat <<EOF
repo1-path=${PGBR_REPO_PATH}
EOF
)
  else
    global_repo_lines=$(cat <<EOF
repo1-type=s3
repo1-path=${PGBR_REPO_PATH}
repo1-s3-bucket=${PGBR_S3_BUCKET}
repo1-s3-endpoint=${PGBR_S3_ENDPOINT}
repo1-s3-region=${PGBR_S3_REGION}
repo1-s3-key=${PGBR_S3_KEY}
repo1-s3-key-secret=${PGBR_S3_KEY_SECRET}
repo1-s3-uri-style=${PGBR_S3_URI_STYLE}
repo1-s3-verify-tls=${PGBR_S3_VERIFY_TLS}
EOF
)
  fi

  cat > /etc/pgbackrest/pgbackrest.conf <<EOF
[global]
repo1-retention-full=${PGBR_RETENTION_FULL}
repo1-retention-diff=${PGBR_RETENTION_DIFF}
compress-type=${PGBR_COMPRESS_TYPE}
process-max=${PGBR_PROCESS_MAX}
archive-async=${PGBR_ARCHIVE_ASYNC}
start-fast=${PGBR_START_FAST}
delta=${PGBR_DELTA}
log-level-file=info
log-path=/var/log/pgbackrest
spool-path=/var/spool/pgbackrest
${global_repo_lines}

[${PGBR_STANZA}]
pg1-path=${data_dir}
pg1-port=${PG_PORT}
pg1-socket-path=/var/run/postgresql
EOF

  chown root:postgres /etc/pgbackrest/pgbackrest.conf
  chmod 0640 /etc/pgbackrest/pgbackrest.conf

  runuser -u postgres -- pgbackrest --stanza="${PGBR_STANZA}" stanza-create
  runuser -u postgres -- psql -Atqc 'SELECT pg_switch_wal();' postgres >/dev/null
  runuser -u postgres -- pgbackrest --stanza="${PGBR_STANZA}" check
}

write_server_env() {
  log "写入服务器端配置快照"
  install -d -m 0700 /etc/pg-center
  cat > /etc/pg-center/pg-center.env <<EOF
PG_MAJOR=${PG_MAJOR}
PG_CLUSTER=${PG_CLUSTER}
PG_PORT=${PG_PORT}
PG_DATA_DIR=$(pg_data_dir)
APP_DB_NAME=${APP_DB_NAME}
APP_DB_USER=${APP_DB_USER}
APP_DB_PASSWORD=${APP_DB_PASSWORD}
PGB_PORT=${PGB_PORT}
PGBR_STANZA=${PGBR_STANZA}
PGBR_REPO_TYPE=${PGBR_REPO_TYPE}
PGBR_REPO_PATH=${PGBR_REPO_PATH}
PGBR_PROCESS_MAX=${PGBR_PROCESS_MAX}
PGBR_COMPRESS_TYPE=${PGBR_COMPRESS_TYPE}
PGBR_RETENTION_FULL=${PGBR_RETENTION_FULL}
PGBR_RETENTION_DIFF=${PGBR_RETENTION_DIFF}
PGBR_FULL_ONCALENDAR="${PGBR_FULL_ONCALENDAR}"
PGBR_INCR_ONCALENDAR="${PGBR_INCR_ONCALENDAR}"
WG_INTERFACE=${WG_INTERFACE}
WG_PORT=${WG_PORT}
WG_MTU=${WG_MTU}
WG_SUBNET=${WG_SUBNET}
WG_SERVER_IP=${WG_SERVER_IP}
WG_CLIENT_DNS=${WG_CLIENT_DNS}
PUBLIC_ENDPOINT=${PUBLIC_ENDPOINT}
EOF
  chmod 0600 /etc/pg-center/pg-center.env

  cat > /root/pg-center-credentials.txt <<EOF
APP_DB_NAME=${APP_DB_NAME}
APP_DB_USER=${APP_DB_USER}
APP_DB_PASSWORD=${APP_DB_PASSWORD}
PGBOUNCER_HOST=${WG_SERVER_IP}
PGBOUNCER_PORT=${PGB_PORT}
WIREGUARD_ENDPOINT=${PUBLIC_ENDPOINT}:${WG_PORT}
DATABASE_URL=postgresql://${APP_DB_USER}:${APP_DB_PASSWORD}@${WG_SERVER_IP}:${PGB_PORT}/${APP_DB_NAME}
PGBACKREST_STANZA=${PGBR_STANZA}
PGBACKREST_REPO_TYPE=${PGBR_REPO_TYPE}
PGBACKREST_REPO_PATH=${PGBR_REPO_PATH}
EOF
  chmod 0600 /root/pg-center-credentials.txt
}

configure_wireguard() {
  local server_private_key
  local server_public_key

  log "配置 WireGuard"
  install -d -m 0700 /etc/wireguard/clients

  if [[ ! -f /etc/wireguard/server_private.key ]]; then
    umask 077
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
  fi

  server_private_key=$(< /etc/wireguard/server_private.key)
  server_public_key=$(< /etc/wireguard/server_public.key)

  if [[ ! -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
    cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/${WG_SUBNET#*/}
MTU = ${WG_MTU}
ListenPort = ${WG_PORT}
PrivateKey = ${server_private_key}
SaveConfig = false
EOF
    chmod 0600 "/etc/wireguard/${WG_INTERFACE}.conf"
  else
    warn "/etc/wireguard/${WG_INTERFACE}.conf 已存在，保留现有 peer 列表"
    if ! grep -q "^Address = ${WG_SERVER_IP}/${WG_SUBNET#*/}$" "/etc/wireguard/${WG_INTERFACE}.conf"; then
      warn "当前 WireGuard 配置的地址不是 ${WG_SERVER_IP}/${WG_SUBNET#*/}，请确认与你的现网规划一致"
    fi

    if grep -q '^MTU = ' "/etc/wireguard/${WG_INTERFACE}.conf"; then
      sed -i "s/^MTU = .*/MTU = ${WG_MTU}/" "/etc/wireguard/${WG_INTERFACE}.conf"
    else
      awk -v mtu="${WG_MTU}" '
        BEGIN { inserted = 0 }
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
      ' "/etc/wireguard/${WG_INTERFACE}.conf" > "/etc/wireguard/${WG_INTERFACE}.conf.tmp"
      mv "/etc/wireguard/${WG_INTERFACE}.conf.tmp" "/etc/wireguard/${WG_INTERFACE}.conf"
      chmod 0600 "/etc/wireguard/${WG_INTERFACE}.conf"
    fi
  fi

  install -m 0755 "${SCRIPT_DIR}/add-wireguard-peer.sh" /usr/local/sbin/pg-center-add-peer
  systemctl enable "wg-quick@${WG_INTERFACE}"
  systemctl restart "wg-quick@${WG_INTERFACE}"

  log "WireGuard 公钥: ${server_public_key}"
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

  ufw allow "${WG_PORT}/udp" comment 'WireGuard' || true
  ufw allow in on "${WG_INTERFACE}" to any port "${PGB_PORT}" proto tcp comment 'PgBouncer over WireGuard' || true
  ufw deny "${PGB_PORT}/tcp" || true
  ufw deny "${PG_PORT}/tcp" || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
}

write_backup_script() {
  cat > /usr/local/sbin/pg-center-backup <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  echo "[pg-center-backup][error] $*" >&2
  exit 1
}

[[ -f /etc/pg-center/pg-center.env ]] || die "缺少 /etc/pg-center/pg-center.env"
source /etc/pg-center/pg-center.env

backup_type=${1:-incr}

case "${backup_type}" in
  full|diff|incr)
    exec runuser -u postgres -- pgbackrest --stanza="${PGBR_STANZA}" --type="${backup_type}" backup
    ;;
  check)
    exec runuser -u postgres -- pgbackrest --stanza="${PGBR_STANZA}" check
    ;;
  info)
    exec runuser -u postgres -- pgbackrest info --stanza="${PGBR_STANZA}"
    ;;
  *)
    die "用法: $0 [full|diff|incr|check|info]"
    ;;
esac
EOF
  chmod 0750 /usr/local/sbin/pg-center-backup
}

write_restore_script() {
  cat > /usr/local/sbin/pg-center-restore <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  echo "[pg-center-restore][error] $*" >&2
  exit 1
}

confirm() {
  local answer
  read -r -p "这会停止 PostgreSQL 并覆盖当前数据目录，继续请输入 yes: " answer
  [[ ${answer} == yes ]]
}

[[ -f /etc/pg-center/pg-center.env ]] || die "缺少 /etc/pg-center/pg-center.env"
source /etc/pg-center/pg-center.env

mode=${1:-latest}
target=${2:-}
service_name="postgresql@${PG_MAJOR}-${PG_CLUSTER}"
data_dir=${PG_DATA_DIR:-/var/lib/postgresql/${PG_MAJOR}/${PG_CLUSTER}}

case "${mode}" in
  latest)
    restore_args=()
    ;;
  time)
    [[ -n ${target} ]] || die "time 模式必须提供目标时间，例如: $0 time '2026-04-21 10:30:00+08'"
    restore_args=(--type=time "--target=${target}")
    ;;
  *)
    die "用法: $0 latest | $0 time '2026-04-21 10:30:00+08'"
    ;;
esac

confirm || die "已取消恢复"

systemctl stop pgbouncer || true
systemctl stop "${service_name}"

if [[ -d ${data_dir} && ! -L ${data_dir} ]]; then
  mv "${data_dir}" "${data_dir}.pre-restore.$(date +%F-%H%M%S)"
fi

install -d -m 0700 -o postgres -g postgres "${data_dir}"
runuser -u postgres -- pgbackrest --stanza="${PGBR_STANZA}" --pg1-path="${data_dir}" "${restore_args[@]}" restore
chown -R postgres:postgres "${data_dir}"

systemctl start "${service_name}"
systemctl start pgbouncer || true

echo "恢复完成。旧数据目录如存在，已改名为 ${data_dir}.pre-restore.*"
EOF
  chmod 0750 /usr/local/sbin/pg-center-restore
}

configure_backup() {
  log "配置 pgBackRest 备份任务"

  write_backup_script
  write_restore_script

  cat > /etc/systemd/system/pg-center-pgbackrest-full.service <<EOF
[Unit]
Description=Run pgBackRest full backup for PG Center
After=network-online.target postgresql@${PG_MAJOR}-${PG_CLUSTER}.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/pg-center-backup full
EOF

  cat > /etc/systemd/system/pg-center-pgbackrest-incr.service <<EOF
[Unit]
Description=Run pgBackRest incremental backup for PG Center
After=network-online.target postgresql@${PG_MAJOR}-${PG_CLUSTER}.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/sbin/pg-center-backup incr
EOF

  cat > /etc/systemd/system/pg-center-pgbackrest-full.timer <<EOF
[Unit]
Description=Weekly pgBackRest full backup timer

[Timer]
OnCalendar=${PGBR_FULL_ONCALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/pg-center-pgbackrest-incr.timer <<EOF
[Unit]
Description=Daily pgBackRest incremental backup timer

[Timer]
OnCalendar=${PGBR_INCR_ONCALENDAR}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pg-center-pgbackrest-full.timer pg-center-pgbackrest-incr.timer
}

show_summary() {
  cat <<EOF

部署完成。

连接入口
  PgBouncer: ${WG_SERVER_IP}:${PGB_PORT}
  PostgreSQL: 仅本机监听 127.0.0.1:${PG_PORT}
  WireGuard: ${PUBLIC_ENDPOINT:-请手工填写}:${WG_PORT}/udp

数据库信息
  数据库名: ${APP_DB_NAME}
  用户名: ${APP_DB_USER}
  密码: 已写入 /root/pg-center-credentials.txt

备份信息
  pgBackRest stanza: ${PGBR_STANZA}
  仓库类型: ${PGBR_REPO_TYPE}
  仓库路径: ${PGBR_REPO_PATH}

常用命令
  systemctl status postgresql@${PG_MAJOR}-${PG_CLUSTER}
  systemctl status pgbouncer
  systemctl status wg-quick@${WG_INTERFACE}
  systemctl list-timers pg-center-pgbackrest-full.timer
  systemctl list-timers pg-center-pgbackrest-incr.timer
  pgadmin
  pgadmin list-users
  pgadmin list-databases
  /usr/local/sbin/pg-center-add-peer peer_name
  /usr/local/sbin/pg-center-backup full
  /usr/local/sbin/pg-center-backup incr
  /usr/local/sbin/pg-center-backup info
  /usr/local/sbin/pg-center-restore latest

下一步
  1. 用 /usr/local/sbin/pg-center-add-peer 为每台客户端生成 WireGuard 配置。
  2. 客户端连到 ${WG_SERVER_IP}:${PGB_PORT}，不要直连 PostgreSQL。
  3. 先执行一次 /usr/local/sbin/pg-center-backup full，确认首个全量备份成功。
EOF
}

main() {
  require_root
  ensure_os
  load_env
  calculate_auto_tuning
  install_packages
  ensure_pg_cluster
  configure_postgresql
  create_database_and_user
  configure_wireguard
  configure_pgbouncer
  configure_pgbackrest
  write_server_env
  install_management_script
  configure_firewall
  configure_backup
  show_summary
}

main "$@"