# MinIO 备份 VPS 方案

这套文件是给第二台 VPS 用的，也就是你的异地备份节点。

目标很简单：

1. 在备份 VPS 上部署 MinIO。
2. 给 pgBackRest 准备一个专用 bucket 和专用访问密钥。
3. 让主库 VPS 把备份写到这个 MinIO 上。
4. 通过 WireGuard 内网通信，保证安全和性能。

## 最推荐的组网方式

最推荐的是让两台 VPS 都在 WireGuard 内网里通信。

这样做的好处：

- MinIO API 不需要暴露公网。
- 不需要额外折腾 HTTPS 也能安全传输，因为 WireGuard 已经加密。
- 防火墙可以只放主库 WireGuard IP 到 MinIO API 端口。

推荐拓扑示例：

- 主库 VPS WireGuard IP: 10.66.0.1
- 备份 VPS WireGuard IP: 10.66.0.2
- MinIO API: 10.66.0.2:9000
- MinIO Console: 127.0.0.1:9001

## 文件说明

- install-minio.sh：在备份 VPS 上执行的一键安装脚本。
- .env.example：备份 VPS 的环境变量模板。
- pgbackrest-primary-snippet.env：主库 VPS 要写入的 pgBackRest 配置片段。

## 备份 VPS 上怎么安装

### 1. 复制模板

    cp .env.example .env

### 2. 修改最关键的值

至少检查这些：

- MINIO_API_ADDRESS
- MINIO_SERVER_URL
- PGBR_BUCKET
- ALLOW_MINIO_CIDR

如果两台机器已经在 WireGuard 里：

- MINIO_API_ADDRESS=10.66.0.2:9000
- MINIO_SERVER_URL=http://10.66.0.2:9000
- ALLOW_MINIO_CIDR=10.66.0.1/32

### 3. 运行安装脚本

    sudo bash install-minio.sh ./.env

安装脚本会做这些事：

- 安装 MinIO 和 mc。
- 创建 minio 系统用户。
- 写 systemd 服务并启动。
- 创建 pgBackRest bucket。
- 创建 pgBackRest 专用访问账号和策略。
- 配置防火墙只允许指定来源访问 9000。
- 输出主库侧应该填写的参数。

安装成功后，备份 VPS 上会生成：

    /root/minio-pgbackrest-credentials.txt

这个文件里会有主库侧需要的 key 和 secret。

## 主库 VPS 怎么切到 MinIO

打开主库上的 [../.env](../.env)，把 pgBackRest 仓库改成 s3。

你可以参考 [pgbackrest-primary-snippet.env](pgbackrest-primary-snippet.env)。

最常见的 WireGuard 内网写法是：

    PGBR_REPO_TYPE=s3
    PGBR_REPO_PATH=/pgbackrest
    PGBR_S3_BUCKET=pgbackrest-prod
    PGBR_S3_ENDPOINT=10.66.0.2:9000
    PGBR_S3_REGION=us-east-1
    PGBR_S3_KEY=pgbackrest
    PGBR_S3_KEY_SECRET=替换成备份 VPS 的 secret
    PGBR_S3_URI_STYLE=path
    PGBR_S3_VERIFY_TLS=n

这里把 PGBR_S3_VERIFY_TLS 设成 n，是因为示例默认走 WireGuard 内网且不额外配置 HTTPS。

## 主库切换后的动作

主库改完 .env 后，重新执行安装脚本，使 pgBackRest 配置重写到系统里：

    cd /home/pg-center-kit
    sudo bash install.sh ./.env

然后手工跑一次：

    sudo /usr/local/sbin/pg-center-backup full

再看：

    sudo /usr/local/sbin/pg-center-backup info

## 怎么验证两台机子串起来了

在备份 VPS 上：

    systemctl status minio

在主库 VPS 上：

    sudo /usr/local/sbin/pg-center-backup full
    sudo /usr/local/sbin/pg-center-backup info

如果成功，备份 VPS 上还可以用 mc 看 bucket：

    mc alias set local http://10.66.0.2:9000 <root-user> <root-password>
    mc ls local/pgbackrest-prod

## 安全建议

- 最好让 MinIO API 只走 WireGuard，不要直接暴露公网。
- Console 维持 127.0.0.1，本地 SSH 隧道访问就够了。
- 不要把 root 凭据直接给 pgBackRest，用脚本生成的专用访问密钥即可。
- 主库和备份 VPS 不要放在同一个服务商同一可用区，如果你真的在意灾备。

## 如果你坚持走公网

也能做，但我不建议作为默认方案。

如果必须公网连接：

- ALLOW_MINIO_CIDR 只放主库公网 IP/32。
- 最好单独给 MinIO 配 HTTPS。
- 主库的 PGBR_S3_VERIFY_TLS 改成 y。