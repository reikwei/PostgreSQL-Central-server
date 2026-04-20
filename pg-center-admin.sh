#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/etc/pg-center/pg-center.env
SELF_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
AUDIT_EXPORT_DIR=/var/log/pg-center/audit

log() {
  echo "[pg-center-admin] $*"
}

die() {
  echo "[pg-center-admin][error] $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "请使用 sudo 运行"
  fi
}

require_env() {
  [[ -f ${ENV_FILE} ]] || die "缺少 ${ENV_FILE}，请先在主库 VPS 上运行 install.sh"
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
}

validate_identifier() {
  local value=$1
  local field_name=$2
  [[ ${value} =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "${field_name} 只能包含字母、数字和下划线，且不能以数字开头"
}

sql_escape_literal() {
  local value=$1
  value=${value//\'/\'\'}
  printf '%s' "${value}"
}

psql_exec() {
  local sql=$1
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 postgres -c "${sql}"
}

psql_query() {
  local sql=$1
  runuser -u postgres -- psql -At -F $'\t' -v ON_ERROR_STOP=1 postgres -c "${sql}"
}

psql_exec_db() {
  local database_name=$1
  local sql=$2
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 "${database_name}" -c "${sql}"
}

psql_query_db() {
  local database_name=$1
  local sql=$2
  runuser -u postgres -- psql -At -F $'\t' -v ON_ERROR_STOP=1 "${database_name}" -c "${sql}"
}

ensure_audit_export_dir() {
  install -d -m 0700 "${AUDIT_EXPORT_DIR}"
}

audit_timestamp() {
  date +%Y%m%d-%H%M%S
}

generate_password() {
  openssl rand -base64 24 | tr -d '\n'
}

sync_pgbouncer_userlist() {
  local userlist_tmp
  local target_group

  userlist_tmp=$(mktemp)
  runuser -u postgres -- psql -At -v ON_ERROR_STOP=1 postgres <<'EOF' > "${userlist_tmp}"
SELECT format('"%s" "%s"', rolname, rolpassword)
FROM pg_authid
WHERE rolcanlogin
  AND rolpassword IS NOT NULL
  AND rolname <> 'postgres'
  AND rolname !~ '^pg_'
ORDER BY rolname;
EOF

  target_group=$(stat -c '%G' /etc/pgbouncer/userlist.txt 2>/dev/null || true)

  if [[ -n ${target_group} ]] && getent group "${target_group}" >/dev/null 2>&1; then
    install -m 0640 "${userlist_tmp}" /etc/pgbouncer/userlist.txt
    chown root:"${target_group}" /etc/pgbouncer/userlist.txt
  else
    install -m 0600 "${userlist_tmp}" /etc/pgbouncer/userlist.txt
  fi

  rm -f "${userlist_tmp}"

  if systemctl is-active --quiet pgbouncer; then
    systemctl reload pgbouncer || systemctl restart pgbouncer
  fi
}

show_connection_string() {
  local database_name=$1
  local user_name=$2

  cat <<EOF
postgresql://${user_name}:<password>@${WG_SERVER_IP}:${PGB_PORT}/${database_name}
EOF
}

list_users() {
  psql_exec "SELECT rolname AS user_name,
                    rolcreatedb AS can_create_db,
                    rolcreaterole AS can_create_role,
                    rolsuper AS is_superuser,
                    rolcanlogin AS can_login
             FROM pg_roles
             WHERE rolname !~ '^pg_'
             ORDER BY rolname;"
}

list_databases() {
  psql_exec "SELECT d.datname AS database_name,
                    pg_catalog.pg_get_userbyid(d.datdba) AS owner_name,
                    pg_size_pretty(pg_database_size(d.datname)) AS size,
                    d.datallowconn AS allow_connections
             FROM pg_database d
             WHERE d.datistemplate = false
             ORDER BY d.datname;"
}

show_user_database_access() {
  local user_name=$1

  validate_identifier "${user_name}" "user_name"
  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"

  if ! psql_query "SELECT d.datname
                  FROM pg_database d
                  CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
                  WHERE d.datistemplate = false
                    AND (
                      d.datdba = r.oid
                      OR has_database_privilege(r.rolname, d.datname, 'CONNECT')
                      OR has_database_privilege(r.rolname, d.datname, 'CREATE')
                      OR has_database_privilege(r.rolname, d.datname, 'TEMPORARY')
                    )
                  LIMIT 1" | grep -q .; then
    echo "用户 ${user_name} 当前没有任何业务数据库权限。"
    return 0
  fi

  psql_exec "SELECT d.datname AS database_name,
                    CASE WHEN d.datdba = r.oid THEN 'yes' ELSE 'no' END AS is_owner,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'CONNECT') THEN 'yes' ELSE 'no' END AS can_connect,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'CREATE') THEN 'yes' ELSE 'no' END AS can_create,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'TEMPORARY') THEN 'yes' ELSE 'no' END AS can_temporary
             FROM pg_database d
             CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
             WHERE d.datistemplate = false
               AND (
                 d.datdba = r.oid
                 OR has_database_privilege(r.rolname, d.datname, 'CONNECT')
                 OR has_database_privilege(r.rolname, d.datname, 'CREATE')
                 OR has_database_privilege(r.rolname, d.datname, 'TEMPORARY')
               )
             ORDER BY d.datname;"
}

show_database_user_access() {
  local database_name=$1

  validate_identifier "${database_name}" "database_name"
  psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1' || die "数据库 ${database_name} 不存在"

  psql_exec "SELECT r.rolname AS user_name,
                    CASE WHEN d.datdba = r.oid THEN 'yes' ELSE 'no' END AS is_owner,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'CONNECT') THEN 'yes' ELSE 'no' END AS can_connect,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'CREATE') THEN 'yes' ELSE 'no' END AS can_create,
                    CASE WHEN has_database_privilege(r.rolname, d.datname, 'TEMPORARY') THEN 'yes' ELSE 'no' END AS can_temporary
             FROM pg_roles r
             CROSS JOIN (SELECT oid, datname, datdba FROM pg_database WHERE datname = '${database_name}') d
             WHERE r.rolname !~ '^pg_'
               AND (
                 d.datdba = r.oid
                 OR has_database_privilege(r.rolname, d.datname, 'CONNECT')
                 OR has_database_privilege(r.rolname, d.datname, 'CREATE')
                 OR has_database_privilege(r.rolname, d.datname, 'TEMPORARY')
               )
             ORDER BY r.rolname;"
}

show_schema_user_access() {
  local database_name=$1
  local schema_name=$2

  validate_identifier "${database_name}" "database_name"
  validate_identifier "${schema_name}" "schema_name"
  psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1' || die "数据库 ${database_name} 不存在"
  psql_query_db "${database_name}" "SELECT 1 FROM pg_namespace WHERE nspname = '${schema_name}'" | grep -qx '1' || die "schema ${schema_name} 不存在于数据库 ${database_name}"

  echo "database=${database_name}"
  echo "schema=${schema_name}"
  echo
  echo "[schema privileges]"
  if psql_query_db "${database_name}" "SELECT 1
                                        FROM pg_roles r
                                        CROSS JOIN (SELECT oid, nspname, nspowner FROM pg_namespace WHERE nspname = '${schema_name}') n
                                        WHERE r.rolname !~ '^pg_'
                                          AND (
                                            n.nspowner = r.oid
                                            OR has_schema_privilege(r.rolname, n.oid, 'USAGE')
                                            OR has_schema_privilege(r.rolname, n.oid, 'CREATE')
                                          )
                                        LIMIT 1" | grep -q .; then
    psql_exec_db "${database_name}" "SELECT r.rolname AS user_name,
                                            CASE WHEN n.nspowner = r.oid THEN 'yes' ELSE 'no' END AS is_owner,
                                            CASE WHEN has_schema_privilege(r.rolname, n.oid, 'USAGE') THEN 'yes' ELSE 'no' END AS can_usage,
                                            CASE WHEN has_schema_privilege(r.rolname, n.oid, 'CREATE') THEN 'yes' ELSE 'no' END AS can_create
                                     FROM pg_roles r
                                     CROSS JOIN (SELECT oid, nspname, nspowner FROM pg_namespace WHERE nspname = '${schema_name}') n
                                     WHERE r.rolname !~ '^pg_'
                                       AND (
                                         n.nspowner = r.oid
                                         OR has_schema_privilege(r.rolname, n.oid, 'USAGE')
                                         OR has_schema_privilege(r.rolname, n.oid, 'CREATE')
                                       )
                                     ORDER BY r.rolname;"
  else
    echo "schema ${schema_name} 当前没有任何非系统角色的 schema 级权限。"
  fi

  echo
  echo "[object privileges summary]"
  if psql_query_db "${database_name}" "SELECT 1
                                        FROM pg_roles r
                                        JOIN pg_class c ON c.relkind IN ('r', 'p', 'v', 'm', 'f')
                                        JOIN pg_namespace n ON n.oid = c.relnamespace
                                        WHERE n.nspname = '${schema_name}'
                                          AND r.rolname !~ '^pg_'
                                          AND (
                                            c.relowner = r.oid
                                            OR has_table_privilege(r.rolname, c.oid, 'SELECT')
                                            OR has_table_privilege(r.rolname, c.oid, 'INSERT')
                                            OR has_table_privilege(r.rolname, c.oid, 'UPDATE')
                                            OR has_table_privilege(r.rolname, c.oid, 'DELETE')
                                            OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE')
                                            OR has_table_privilege(r.rolname, c.oid, 'REFERENCES')
                                            OR has_table_privilege(r.rolname, c.oid, 'TRIGGER')
                                          )
                                        LIMIT 1" | grep -q .; then
    psql_exec_db "${database_name}" "SELECT r.rolname AS user_name,
                                            COUNT(DISTINCT c.oid) AS object_count,
                                            CASE WHEN bool_or(c.relowner = r.oid) THEN 'yes' ELSE 'no' END AS owns_any_object,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'SELECT')) THEN 'yes' ELSE 'no' END AS any_select,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'INSERT')) THEN 'yes' ELSE 'no' END AS any_insert,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'UPDATE')) THEN 'yes' ELSE 'no' END AS any_update,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'DELETE')) THEN 'yes' ELSE 'no' END AS any_delete,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'TRUNCATE')) THEN 'yes' ELSE 'no' END AS any_truncate,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'REFERENCES')) THEN 'yes' ELSE 'no' END AS any_references,
                                            CASE WHEN bool_or(has_table_privilege(r.rolname, c.oid, 'TRIGGER')) THEN 'yes' ELSE 'no' END AS any_trigger
                                     FROM pg_roles r
                                     JOIN pg_class c ON c.relkind IN ('r', 'p', 'v', 'm', 'f')
                                     JOIN pg_namespace n ON n.oid = c.relnamespace
                                     WHERE n.nspname = '${schema_name}'
                                       AND r.rolname !~ '^pg_'
                                       AND (
                                         c.relowner = r.oid
                                         OR has_table_privilege(r.rolname, c.oid, 'SELECT')
                                         OR has_table_privilege(r.rolname, c.oid, 'INSERT')
                                         OR has_table_privilege(r.rolname, c.oid, 'UPDATE')
                                         OR has_table_privilege(r.rolname, c.oid, 'DELETE')
                                         OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE')
                                         OR has_table_privilege(r.rolname, c.oid, 'REFERENCES')
                                         OR has_table_privilege(r.rolname, c.oid, 'TRIGGER')
                                       )
                                     GROUP BY r.rolname
                                     ORDER BY r.rolname;"
  else
    echo "schema ${schema_name} 下当前没有任何非系统角色的对象级权限。"
  fi
}

show_user_object_access() {
  local user_name=$1
  local database_filter=${2:-}
  local found_any=0
  local database_name
  local -a databases

  validate_identifier "${user_name}" "user_name"
  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"

  if [[ -n ${database_filter} ]]; then
    validate_identifier "${database_filter}" "database_name"
    psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_filter}'" | grep -qx '1' || die "数据库 ${database_filter} 不存在"
    databases=("${database_filter}")
  else
    mapfile -t databases < <(psql_query "SELECT datname
                                      FROM pg_database
                                      WHERE datistemplate = false
                                      ORDER BY datname")
  fi

  for database_name in "${databases[@]}"; do
    if ! psql_query_db "${database_name}" "SELECT 1
                                        FROM pg_namespace n
                                        CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
                                        WHERE n.nspname <> 'information_schema'
                                          AND n.nspname !~ '^pg_'
                                          AND (
                                            n.nspowner = r.oid
                                            OR has_schema_privilege(r.rolname, n.oid, 'USAGE')
                                            OR has_schema_privilege(r.rolname, n.oid, 'CREATE')
                                          )
                                        LIMIT 1" | grep -q . && \
       ! psql_query_db "${database_name}" "SELECT 1
                                        FROM pg_class c
                                        JOIN pg_namespace n ON n.oid = c.relnamespace
                                        CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
                                        WHERE n.nspname <> 'information_schema'
                                          AND n.nspname !~ '^pg_'
                                          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                                          AND (
                                            c.relowner = r.oid
                                            OR has_table_privilege(r.rolname, c.oid, 'SELECT')
                                            OR has_table_privilege(r.rolname, c.oid, 'INSERT')
                                            OR has_table_privilege(r.rolname, c.oid, 'UPDATE')
                                            OR has_table_privilege(r.rolname, c.oid, 'DELETE')
                                            OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE')
                                            OR has_table_privilege(r.rolname, c.oid, 'REFERENCES')
                                            OR has_table_privilege(r.rolname, c.oid, 'TRIGGER')
                                          )
                                        LIMIT 1" | grep -q .; then
      continue
    fi

    found_any=1
    echo
    echo "===== database: ${database_name} ====="
    echo
    echo "[schema privileges]"
    psql_exec_db "${database_name}" "SELECT n.nspname AS schema_name,
                                            CASE WHEN n.nspowner = r.oid THEN 'yes' ELSE 'no' END AS is_owner,
                                            CASE WHEN has_schema_privilege(r.rolname, n.oid, 'USAGE') THEN 'yes' ELSE 'no' END AS can_usage,
                                            CASE WHEN has_schema_privilege(r.rolname, n.oid, 'CREATE') THEN 'yes' ELSE 'no' END AS can_create
                                     FROM pg_namespace n
                                     CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
                                     WHERE n.nspname <> 'information_schema'
                                       AND n.nspname !~ '^pg_'
                                       AND (
                                         n.nspowner = r.oid
                                         OR has_schema_privilege(r.rolname, n.oid, 'USAGE')
                                         OR has_schema_privilege(r.rolname, n.oid, 'CREATE')
                                       )
                                     ORDER BY n.nspname;"

    echo
    echo "[table privileges]"
    psql_exec_db "${database_name}" "SELECT n.nspname AS schema_name,
                                            c.relname AS object_name,
                                            CASE c.relkind
                                              WHEN 'r' THEN 'table'
                                              WHEN 'p' THEN 'partitioned_table'
                                              WHEN 'v' THEN 'view'
                                              WHEN 'm' THEN 'materialized_view'
                                              WHEN 'f' THEN 'foreign_table'
                                              ELSE c.relkind::text
                                            END AS object_type,
                                            CASE WHEN c.relowner = r.oid THEN 'yes' ELSE 'no' END AS is_owner,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'SELECT') THEN 'yes' ELSE 'no' END AS can_select,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'INSERT') THEN 'yes' ELSE 'no' END AS can_insert,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'UPDATE') THEN 'yes' ELSE 'no' END AS can_update,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'DELETE') THEN 'yes' ELSE 'no' END AS can_delete,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'TRUNCATE') THEN 'yes' ELSE 'no' END AS can_truncate,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'REFERENCES') THEN 'yes' ELSE 'no' END AS can_references,
                                            CASE WHEN has_table_privilege(r.rolname, c.oid, 'TRIGGER') THEN 'yes' ELSE 'no' END AS can_trigger
                                     FROM pg_class c
                                     JOIN pg_namespace n ON n.oid = c.relnamespace
                                     CROSS JOIN (SELECT oid, rolname FROM pg_roles WHERE rolname = '${user_name}') r
                                     WHERE n.nspname <> 'information_schema'
                                       AND n.nspname !~ '^pg_'
                                       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                                       AND (
                                         c.relowner = r.oid
                                         OR has_table_privilege(r.rolname, c.oid, 'SELECT')
                                         OR has_table_privilege(r.rolname, c.oid, 'INSERT')
                                         OR has_table_privilege(r.rolname, c.oid, 'UPDATE')
                                         OR has_table_privilege(r.rolname, c.oid, 'DELETE')
                                         OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE')
                                         OR has_table_privilege(r.rolname, c.oid, 'REFERENCES')
                                         OR has_table_privilege(r.rolname, c.oid, 'TRIGGER')
                                       )
                                     ORDER BY n.nspname, c.relname;"
  done

  if [[ ${found_any} -eq 0 ]]; then
    echo "用户 ${user_name} 在业务数据库中当前没有任何 schema 或表级权限。"
  fi
}

export_user_audit_summary() {
  local user_name=$1
  local database_filter=${2:-}
  local timestamp
  local output_file

  validate_identifier "${user_name}" "user_name"
  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"

  if [[ -n ${database_filter} ]]; then
    validate_identifier "${database_filter}" "database_name"
    psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_filter}'" | grep -qx '1' || die "数据库 ${database_filter} 不存在"
  fi

  ensure_audit_export_dir
  timestamp=$(audit_timestamp)
  if [[ -n ${database_filter} ]]; then
    output_file="${AUDIT_EXPORT_DIR}/user-${user_name}-${database_filter}-${timestamp}.txt"
  else
    output_file="${AUDIT_EXPORT_DIR}/user-${user_name}-${timestamp}.txt"
  fi

  {
    echo "pg-center-admin audit summary"
    echo "generated_at=$(date -Is)"
    echo "scope=user"
    echo "user=${user_name}"
    if [[ -n ${database_filter} ]]; then
      echo "database_filter=${database_filter}"
    fi
    echo
    echo "== database privileges =="
    show_user_database_access "${user_name}"
    echo
    echo "== schema and table privileges =="
    if [[ -n ${database_filter} ]]; then
      show_user_object_access "${user_name}" "${database_filter}"
    else
      show_user_object_access "${user_name}"
    fi
  } > "${output_file}"

  echo "AUDIT_FILE=${output_file}"
}

export_database_audit_summary() {
  local database_name=$1
  local timestamp
  local output_file
  local schema_name
  local -a schemas

  validate_identifier "${database_name}" "database_name"
  psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1' || die "数据库 ${database_name} 不存在"

  ensure_audit_export_dir
  timestamp=$(audit_timestamp)
  output_file="${AUDIT_EXPORT_DIR}/database-${database_name}-${timestamp}.txt"

  mapfile -t schemas < <(psql_query_db "${database_name}" "SELECT nspname
                                                         FROM pg_namespace
                                                         WHERE nspname <> 'information_schema'
                                                           AND nspname !~ '^pg_'
                                                         ORDER BY nspname")

  {
    echo "pg-center-admin audit summary"
    echo "generated_at=$(date -Is)"
    echo "scope=database"
    echo "database=${database_name}"
    echo
    echo "== database privileges =="
    show_database_user_access "${database_name}"

    for schema_name in "${schemas[@]}"; do
      echo
      echo "== schema ${schema_name} =="
      show_schema_user_access "${database_name}" "${schema_name}"
    done
  } > "${output_file}"

  echo "AUDIT_FILE=${output_file}"
}

create_user() {
  local user_name=$1
  local password=${2:-}
  local escaped_password

  validate_identifier "${user_name}" "user_name"

  if [[ -z ${password} ]]; then
    password=$(generate_password)
  fi
  escaped_password=$(sql_escape_literal "${password}")

  if psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1'; then
    die "用户 ${user_name} 已存在"
  fi

  psql_exec "CREATE ROLE \"${user_name}\" LOGIN PASSWORD '${escaped_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE;"
  sync_pgbouncer_userlist

  echo "USER=${user_name}"
  echo "PASSWORD=${password}"
}

reset_password() {
  local user_name=$1
  local password=${2:-}
  local escaped_password

  validate_identifier "${user_name}" "user_name"

  if [[ -z ${password} ]]; then
    password=$(generate_password)
  fi
  escaped_password=$(sql_escape_literal "${password}")

  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"
  psql_exec "ALTER ROLE \"${user_name}\" WITH LOGIN PASSWORD '${escaped_password}';"
  sync_pgbouncer_userlist

  echo "USER=${user_name}"
  echo "PASSWORD=${password}"
}

disable_user() {
  local user_name=$1

  validate_identifier "${user_name}" "user_name"
  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"
  psql_exec "ALTER ROLE \"${user_name}\" NOLOGIN;"
  sync_pgbouncer_userlist
}

drop_user() {
  local user_name=$1

  validate_identifier "${user_name}" "user_name"
  [[ ${user_name} != "postgres" ]] || die "不允许删除 postgres"

  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${user_name}'" | grep -qx '1' || die "用户 ${user_name} 不存在"

  if psql_query "SELECT datname FROM pg_database WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '${user_name}') LIMIT 1" | grep -q .; then
    die "用户 ${user_name} 仍拥有数据库，请先转移数据库所有者或删除数据库"
  fi

  psql_exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '${user_name}' AND pid <> pg_backend_pid();"
  psql_exec "DROP ROLE \"${user_name}\";"
  sync_pgbouncer_userlist
}

create_database() {
  local database_name=$1
  local owner_name=$2

  validate_identifier "${database_name}" "database_name"
  validate_identifier "${owner_name}" "owner_name"

  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${owner_name}'" | grep -qx '1' || die "用户 ${owner_name} 不存在"

  if psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1'; then
    die "数据库 ${database_name} 已存在"
  fi

  runuser -u postgres -- createdb -O "${owner_name}" "${database_name}"
  psql_exec "GRANT ALL PRIVILEGES ON DATABASE \"${database_name}\" TO \"${owner_name}\";"
  show_connection_string "${database_name}" "${owner_name}"
}

change_database_owner() {
  local database_name=$1
  local owner_name=$2

  validate_identifier "${database_name}" "database_name"
  validate_identifier "${owner_name}" "owner_name"

  psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1' || die "数据库 ${database_name} 不存在"
  psql_query "SELECT 1 FROM pg_roles WHERE rolname = '${owner_name}'" | grep -qx '1' || die "用户 ${owner_name} 不存在"

  psql_exec "ALTER DATABASE \"${database_name}\" OWNER TO \"${owner_name}\";"
  psql_exec "GRANT ALL PRIVILEGES ON DATABASE \"${database_name}\" TO \"${owner_name}\";"
}

drop_database() {
  local database_name=$1

  validate_identifier "${database_name}" "database_name"
  [[ ${database_name} != "postgres" ]] || die "不允许删除 postgres"

  psql_query "SELECT 1 FROM pg_database WHERE datname = '${database_name}'" | grep -qx '1' || die "数据库 ${database_name} 不存在"
  psql_exec "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${database_name}' AND pid <> pg_backend_pid();"
  runuser -u postgres -- dropdb "${database_name}"
}

create_app() {
  local database_name=$1
  local user_name=$2
  local password=${3:-}

  create_user "${user_name}" "${password}"
  create_database "${database_name}" "${user_name}"
}

usage() {
  cat <<EOF
用法: $0 <command> [args]

命令:
  list-users
  list-databases
  show-user-database-access <user>
  show-database-user-access <database>
  show-schema-user-access <database> <schema>
  show-user-object-access <user> [database]
  export-user-audit-summary <user> [database]
  export-database-audit-summary <database>
  create-user <user> [password]
  reset-password <user> [password]
  disable-user <user>
  drop-user <user>
  create-database <database> <owner>
  change-database-owner <database> <owner>
  drop-database <database>
  create-app <database> <user> [password]
  sync-pgbouncer-users

说明:
  1. 这个脚本只能在主库 VPS 上运行。
  2. 所有用户改动后会自动同步 PgBouncer 的 userlist。
  3. 更推荐先 disable-user，再评估是否 drop-user。
  4. 不带参数直接运行时，会进入交互式数字菜单。
EOF
}

pause_prompt() {
  local reply
  read -r -p "按 Enter 继续..." reply || true
}

prompt_required() {
  local prompt_text=$1
  local value

  while true; do
    read -r -p "${prompt_text}: " value
    if [[ -n ${value} ]]; then
      printf '%s' "${value}"
      return 0
    fi
    echo "输入不能为空。" >&2
  done
}

prompt_optional() {
  local prompt_text=$1
  local value

  read -r -p "${prompt_text}: " value
  printf '%s' "${value}"
}

prompt_optional_secret() {
  local prompt_text=$1
  local secret
  local confirm_secret

  while true; do
    read -r -s -p "${prompt_text}（留空则自动生成）: " secret
    echo

    if [[ -z ${secret} ]]; then
      printf '%s' ""
      return 0
    fi

    read -r -s -p "再次输入密码确认: " confirm_secret
    echo

    if [[ ${secret} == ${confirm_secret} ]]; then
      printf '%s' "${secret}"
      return 0
    fi

    echo "两次输入的密码不一致，请重新输入。" >&2
  done
}

confirm_yes() {
  local prompt_text=$1
  local answer

  read -r -p "${prompt_text}，请输入 yes 确认: " answer
  [[ ${answer} == yes ]]
}

confirm_exact_match() {
  local object_type=$1
  local expected_value=$2
  local actual_value

  read -r -p "为安全起见，请输入要操作的${object_type}名称 ${expected_value} 以确认: " actual_value
  [[ ${actual_value} == ${expected_value} ]]
}

run_subcommand() {
  "${SELF_PATH}" "$@"
}

interactive_menu() {
  local choice
  local user_name
  local database_name
  local schema_name
  local owner_name
  local password

  while true; do
    cat <<'EOF'

pg-center-admin 交互菜单
  1. 查询用户列表
  2. 查询数据库列表
  3. 查看某个用户拥有哪些数据库级权限
  4. 查看某个数据库下哪些用户有数据库级权限
  5. 查看某个用户在各 schema 和表上的权限
  6. 查看某个 schema 下哪些用户有权限
  7. 导出某个用户的权限审计摘要
  8. 导出某个数据库的权限审计摘要
  9. 新建用户
  10. 重置用户密码
  11. 停用用户
  12. 删除用户
  13. 新建数据库
  14. 修改数据库所有者
  15. 删除数据库
  16. 一次性创建数据库 + 用户
  17. 同步 PgBouncer 用户清单
  0. 退出
EOF

    read -r -p "请选择编号: " choice

    case "${choice}" in
      1)
        run_subcommand list-users || true
        pause_prompt
        ;;
      2)
        run_subcommand list-databases || true
        pause_prompt
        ;;
      3)
        user_name=$(prompt_required "输入要查询的用户名")
        run_subcommand show-user-database-access "${user_name}" || true
        pause_prompt
        ;;
      4)
        database_name=$(prompt_required "输入要查询的数据库名")
        run_subcommand show-database-user-access "${database_name}" || true
        pause_prompt
        ;;
      5)
        user_name=$(prompt_required "输入要查询的用户名")
        database_name=$(prompt_optional "输入数据库名（留空则检查全部业务数据库）")
        if [[ -n ${database_name} ]]; then
          run_subcommand show-user-object-access "${user_name}" "${database_name}" || true
        else
          run_subcommand show-user-object-access "${user_name}" || true
        fi
        pause_prompt
        ;;
      6)
        database_name=$(prompt_required "输入数据库名")
        schema_name=$(prompt_required "输入 schema 名")
        run_subcommand show-schema-user-access "${database_name}" "${schema_name}" || true
        pause_prompt
        ;;
      7)
        user_name=$(prompt_required "输入要导出的用户名")
        database_name=$(prompt_optional "输入数据库名（留空则导出全部业务数据库）")
        if [[ -n ${database_name} ]]; then
          run_subcommand export-user-audit-summary "${user_name}" "${database_name}" || true
        else
          run_subcommand export-user-audit-summary "${user_name}" || true
        fi
        pause_prompt
        ;;
      8)
        database_name=$(prompt_required "输入要导出的数据库名")
        run_subcommand export-database-audit-summary "${database_name}" || true
        pause_prompt
        ;;
      9)
        user_name=$(prompt_required "输入新用户名")
        password=$(prompt_optional_secret "输入密码")
        if [[ -n ${password} ]]; then
          run_subcommand create-user "${user_name}" "${password}" || true
        else
          run_subcommand create-user "${user_name}" || true
        fi
        pause_prompt
        ;;
      10)
        user_name=$(prompt_required "输入要重置密码的用户名")
        password=$(prompt_optional_secret "输入新密码")
        if [[ -n ${password} ]]; then
          run_subcommand reset-password "${user_name}" "${password}" || true
        else
          run_subcommand reset-password "${user_name}" || true
        fi
        pause_prompt
        ;;
      11)
        user_name=$(prompt_required "输入要停用的用户名")
        if confirm_exact_match "用户名" "${user_name}"; then
          run_subcommand disable-user "${user_name}" || true
        else
          echo "已取消。"
        fi
        pause_prompt
        ;;
      12)
        user_name=$(prompt_required "输入要删除的用户名")
        if confirm_exact_match "用户名" "${user_name}"; then
          run_subcommand drop-user "${user_name}" || true
        else
          echo "已取消。"
        fi
        pause_prompt
        ;;
      13)
        database_name=$(prompt_required "输入新数据库名")
        owner_name=$(prompt_required "输入数据库所有者用户名")
        run_subcommand create-database "${database_name}" "${owner_name}" || true
        pause_prompt
        ;;
      14)
        database_name=$(prompt_required "输入数据库名")
        owner_name=$(prompt_required "输入新的所有者用户名")
        run_subcommand change-database-owner "${database_name}" "${owner_name}" || true
        pause_prompt
        ;;
      15)
        database_name=$(prompt_required "输入要删除的数据库名")
        if confirm_exact_match "数据库名" "${database_name}"; then
          run_subcommand drop-database "${database_name}" || true
        else
          echo "已取消。"
        fi
        pause_prompt
        ;;
      16)
        database_name=$(prompt_required "输入新数据库名")
        user_name=$(prompt_required "输入新用户名")
        password=$(prompt_optional_secret "输入密码")
        if [[ -n ${password} ]]; then
          run_subcommand create-app "${database_name}" "${user_name}" "${password}" || true
        else
          run_subcommand create-app "${database_name}" "${user_name}" || true
        fi
        pause_prompt
        ;;
      17)
        run_subcommand sync-pgbouncer-users || true
        pause_prompt
        ;;
      0)
        exit 0
        ;;
      *)
        echo "无效编号，请重新输入。"
        ;;
    esac
  done
}

main() {
  local command=${1:-}

  require_root
  require_env

  if [[ -z ${command} ]]; then
    interactive_menu
    return 0
  fi

  case "${command}" in
    list-users)
      list_users
      ;;
    list-databases)
      list_databases
      ;;
    show-user-database-access)
      [[ $# -eq 2 ]] || die "用法: $0 show-user-database-access <user>"
      show_user_database_access "$2"
      ;;
    show-database-user-access)
      [[ $# -eq 2 ]] || die "用法: $0 show-database-user-access <database>"
      show_database_user_access "$2"
      ;;
    show-schema-user-access)
      [[ $# -eq 3 ]] || die "用法: $0 show-schema-user-access <database> <schema>"
      show_schema_user_access "$2" "$3"
      ;;
    show-user-object-access)
      [[ $# -ge 2 && $# -le 3 ]] || die "用法: $0 show-user-object-access <user> [database]"
      show_user_object_access "$2" "${3:-}"
      ;;
    export-user-audit-summary)
      [[ $# -ge 2 && $# -le 3 ]] || die "用法: $0 export-user-audit-summary <user> [database]"
      export_user_audit_summary "$2" "${3:-}"
      ;;
    export-database-audit-summary)
      [[ $# -eq 2 ]] || die "用法: $0 export-database-audit-summary <database>"
      export_database_audit_summary "$2"
      ;;
    create-user)
      [[ $# -ge 2 ]] || die "用法: $0 create-user <user> [password]"
      create_user "$2" "${3:-}"
      ;;
    reset-password)
      [[ $# -ge 2 ]] || die "用法: $0 reset-password <user> [password]"
      reset_password "$2" "${3:-}"
      ;;
    disable-user)
      [[ $# -eq 2 ]] || die "用法: $0 disable-user <user>"
      disable_user "$2"
      ;;
    drop-user)
      [[ $# -eq 2 ]] || die "用法: $0 drop-user <user>"
      drop_user "$2"
      ;;
    create-database)
      [[ $# -eq 3 ]] || die "用法: $0 create-database <database> <owner>"
      create_database "$2" "$3"
      ;;
    change-database-owner)
      [[ $# -eq 3 ]] || die "用法: $0 change-database-owner <database> <owner>"
      change_database_owner "$2" "$3"
      ;;
    drop-database)
      [[ $# -eq 2 ]] || die "用法: $0 drop-database <database>"
      drop_database "$2"
      ;;
    create-app)
      [[ $# -ge 3 ]] || die "用法: $0 create-app <database> <user> [password]"
      create_app "$2" "$3" "${4:-}"
      ;;
    sync-pgbouncer-users)
      sync_pgbouncer_userlist
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "未知命令: ${command}"
      ;;
  esac
}

main "$@"