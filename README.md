# PostgreSQL Central Server

一个面向单主生产环境的 PostgreSQL 中心库部署套件。

它把 PostgreSQL、PgBouncer、WireGuard 和 pgBackRest 组合成一套可直接落地的方案：数据库不暴露公网、业务统一走连接池、客户端通过内网隧道接入、备份和 WAL 归档默认纳入交付范围。

## 产品定位

PostgreSQL Central Server 适合这样的场景：

- 你需要一台中心数据库服务器，给多台业务机或机器人节点统一提供数据库服务。
- 你不想把 PostgreSQL 5432 直接暴露在公网。
- 你希望应用侧永远连接一个固定内网入口，而不是直连主库。
- 你希望数据库备份、WAL 归档、权限管理和运维入口从第一天就标准化。

这不是一个“只装 PostgreSQL”的脚本仓库，而是一套偏产品化的中心库交付包。

## 核心能力

- PostgreSQL 单主部署，数据库仅监听本机。
- PgBouncer 对外提供统一连接入口，缓解连接数膨胀。
- WireGuard 为所有业务节点建立私有接入面，隐藏数据库公网暴露。
- pgBackRest 提供全量、增量、WAL 归档和时间点恢复能力。
- 主库内置运维管理脚本，统一完成用户、数据库和权限变更。
- 子节点可直接使用连通性检查脚本排障。

## 架构概览

- 公网开放端口仅建议保留 SSH 和 WireGuard。
- PostgreSQL 绑定到 127.0.0.1:5432。
- PgBouncer 绑定到 WireGuard 地址 10.66.0.1:6432。
- 所有业务机先接入 WireGuard，再访问 10.66.0.1:6432。
- 当前 peer 自动分配逻辑按 /24 网段设计，因此 WG_SUBNET 应保持类似 10.66.0.0/24。

组件边界如下：

- PgBouncer 负责连接治理，不负责网络隔离和备份。
- WireGuard 负责私网接入，不负责连接池和恢复链路。
- pgBackRest 负责备份、归档和恢复，不负责在线连接治理。

## 适合谁用

- 需要把多个机器人、爬虫节点、业务 VPS 统一接入一个数据库中心的团队。
- 想在低运维成本前提下交付一套更安全的 PostgreSQL 方案的个人开发者。
- 需要将“装库、开池、建隧道、做备份、做审计”一次性交付的运维场景。

## 仓库内容

- install.sh：主库一键安装脚本。
- pg-center-admin.sh：主库统一管理入口。
- add-wireguard-peer.sh：新增业务节点 peer 并生成客户端配置。
- install-wireguard-client.sh：在业务节点导入并启用 WireGuard。
- check-pg-center-connectivity.sh：业务节点连通性复测脚本。
- s3minlo/install-minio.sh：自建 MinIO 场景的辅助脚本。

## 快速开始

### 1. 准备配置

复制模板：

```bash
cp .env.example .env
```

至少要检查并修改这些参数：

- APP_DB_PASSWORD
- PUBLIC_ENDPOINT
- ALLOW_SSH_CIDR
- PGBR_REPO_TYPE
- PGBR_REPO_PATH

如果备份仓库使用 S3 兼容对象存储，还需要填写：

- PGBR_S3_BUCKET
- PGBR_S3_ENDPOINT
- PGBR_S3_REGION
- PGBR_S3_KEY
- PGBR_S3_KEY_SECRET

### 2. 安装主库

```bash
sudo bash install.sh ./.env
```

安装脚本会自动完成：

- 安装 PostgreSQL 16、PgBouncer、WireGuard、UFW、pgBackRest。
- 创建业务数据库和业务账号。
- 将 PostgreSQL 限制为仅监听本机。
- 将 PgBouncer 暴露到 WireGuard 私网地址。
- 初始化 pgBackRest 仓库并开启 WAL 归档。
- 配置全量与增量备份定时任务。
- 安装恢复与运维辅助脚本。

### 3. 首次执行全量备份

```bash
sudo /usr/local/sbin/pg-center-backup full
sudo /usr/local/sbin/pg-center-backup info
```

### 4. 为业务节点生成 WireGuard 配置

```bash
sudo /usr/local/sbin/pg-center-add-peer bot-001
```

生成的客户端配置默认位于：

```bash
/etc/wireguard/clients/bot-001.conf
```

### 5. 在子节点启用 WireGuard

先把配置传到业务机，然后在业务机执行：

```bash
sudo bash install-wireguard-client.sh /tmp/bot-001.conf
```

如果你希望接口名固定为 wg0：

```bash
sudo bash install-wireguard-client.sh /tmp/bot-001.conf wg0
```

安装完成后，业务节点统一通过以下入口连接数据库：

- Host: 10.66.0.1
- Port: 6432
- Database: 你的 APP_DB_NAME
- User: 你的 APP_DB_USER
- Password: 你的 APP_DB_PASSWORD

### 6. 业务节点复测连通性

```bash
sudo bash check-pg-center-connectivity.sh 10.66.0.1 6432 wg0
```

如果脚本已安装到系统，也可以直接运行：

```bash
sudo /usr/local/sbin/pg-center-check-connectivity 10.66.0.1 6432 wg0
```

它会检查 WireGuard 状态、路由和 PgBouncer 端口可达性，并在失败时打印排障信息。

## 运维模型

推荐把数据库运维权限收口在主库上，不把数据库超级权限和 Linux root 下放给业务节点。

建议模型：

- 子 VPS 只拿业务数据库账号，只能连接自己的数据库。
- 主库 VPS 才有新增库、建用户、改密码、停用用户和删库权限。
- 所有管理动作通过统一脚本执行，避免人工散落敲 SQL。

主库安装后统一使用：

```bash
sudo /usr/local/sbin/pg-center-admin
```

同时也会安装快捷命令：

```bash
pgadmin
```

管理脚本支持两种模式：

- 直接运行，进入数字菜单交互模式。
- 带参数运行，进入命令行模式。

常见能力包括：

- 查询数据库和用户列表。
- 查看数据库级、schema 级、表级权限。
- 导出用户或数据库的权限审计摘要。
- 新建用户、重置密码、修改 postgres 密码、停用用户、删除用户。
- 新建数据库、修改所有者、删除数据库。
- 一次性创建数据库和用户。
- 查看 postgres 超级用户的本机直连方式说明。
- 每次用户变更后自动同步 PgBouncer userlist。

常用命令示例：

```bash
pgadmin reset-postgres-password
pgadmin show-postgres-connection-help
```

关于 postgres 超级用户，建议这样使用：

- postgres 只用于主库本机上的管理和应急操作，不用于业务应用连接。
- postgres 不走 PgBouncer，连接目标应为 127.0.0.1:5432。
- 如果已经为主库生成过超级用户凭据，可查看 /root/postgres-superuser-credentials.txt。
- 如果密码遗失，可随时执行 pgadmin reset-postgres-password 重新生成。

审计导出默认输出到：

```bash
/var/log/pg-center/audit
```

## 参数建议

关于 PG_SYNCHRONOUS_COMMIT：

- 如果你更在意吞吐并接受极小窗口数据丢失，可保持 off。
- 如果你更在意已确认事务的稳妥性，建议改成 on。
- pgBackRest 只能保护已经进入持久化和备份链路的数据，不能挽回尚未真正落盘的事务。

## 备份仓库模式

### 本地仓库

```env
PGBR_REPO_TYPE=local
PGBR_REPO_PATH=/var/lib/pgbackrest
```

### S3 兼容对象存储

```env
PGBR_REPO_TYPE=s3
PGBR_REPO_PATH=/pgbackrest
PGBR_S3_BUCKET=your-bucket
PGBR_S3_ENDPOINT=your-endpoint
PGBR_S3_REGION=your-region
PGBR_S3_KEY=your-access-key
PGBR_S3_KEY_SECRET=your-secret-key
```

如果你使用自建 MinIO，可参考 [s3minlo/README.md](s3minlo/README.md)。

## 公开仓库建议

- 不要把实际生产用的 .env 上传到公开仓库。
- 公开仓库只保留 .env.example 作为模板。
- 发布前建议确认仓库里没有真实 IP 白名单、访问密钥或业务密码。

## 备份与恢复

默认备份策略：

- 每周日 03:20 执行一次全量备份。
- 周一到周六 03:20 执行一次增量备份。
- 默认保留 2 份 full 和 6 份 diff 链参数。

常用命令：

```bash
sudo /usr/local/sbin/pg-center-backup full
sudo /usr/local/sbin/pg-center-backup incr
sudo /usr/local/sbin/pg-center-backup check
sudo /usr/local/sbin/pg-center-backup info
```

恢复到最新可用点：

```bash
sudo /usr/local/sbin/pg-center-restore latest
```

恢复到指定时间点：

```bash
sudo /usr/local/sbin/pg-center-restore time '2026-04-21 10:30:00+08'
```

## 运维建议

- 中心库 VPS 尽量不要混跑其它公网服务。
- SSH 建议仅允许密钥登录，并收紧 ALLOW_SSH_CIDR。
- 上线前至少验证一次完整恢复流程，而不是只验证备份成功。
- 初期建议用压测验证 transaction 池模式是否与业务代码兼容。
