# PGV · Tabularis

VOS 的 PGV 分组下只有两个并列子页面：**数据库连接器**和**接入指南**。指南包含接入、建库、初始账户、配置参考和完整迁移维护文档。

该应用统一提供 PostgreSQL 17、共享 Redis 和 Tabularis 数据管理界面。
在 VOS 侧边栏打开 PGV，使用 VOS 管理员登录后，PostgreSQL 与 Redis 会自动连接，
无需手动输入数据库凭据。启动时不显示社区推广弹窗，直接进入数据库工作区。
支持 SQL 查询、表数据浏览和 Redis 键值查看。

原 PGV 的应用 ID、PostgreSQL 地址、宿主机端口、业务数据库、用户和数据目录保持兼容。
应用在 `vos_default` Docker 网络中为 WeKnora、Immich、Nowen Video 预置独立数据库、用户和扩展。

从旧 PGV（包括 0.0.33）更新时，安装器按实际 PostgreSQL 版本和扩展自动迁移
PG16 数据，成功恢复、初始化后才切换到 PG17，并保留原 PG16 目录和备份。
迁移镜像同时包含 PG16/PG17 PostGIS；普通用户无需终端操作。
失败时原数据仍为 PG16；零字节文件及 `.partial` 文件不属于有效备份。
管理员故障恢复可使用安装包内的 `recover-pg16.sh`；该脚本先做独立离线备份，
再调用同一自动迁移流程。

界面语言自动跟随 VOS，支持首次打开和运行时切换中英文；侧栏不显示 Discord 推广入口。
顶部浅蓝色“生产”标记提醒当前连接为共享业务数据库，并非错误。
左上角与 VOS 应用列表统一使用蓝青色 V 形立方体 PGV 图标。

## 网络地址

其他同在 `vos_default` 网络内的容器使用：

```text
pgv:5432
```

为兼容旧应用，`shared-pgv:5432` 仍会保留。不要使用裸 `postgres:5432`，
避免解析到 VOS 平台或其他应用的 Postgres。

应用默认将 Postgres 暴露到宿主机 `25432` 端口。`vos_default` 网络内的
容器仍建议使用 `pgv:5432`；宿主机端口主要用于调试或 Docker
网络外客户端接入。

## 数据浏览器

应用自带 Tabularis 数据浏览器，用于查看数据库、表和行数据。安装后会通过 `routers.yml`
在 VOS 侧边栏注册独立的 `PGV` 顶级页面。
数据浏览器按安装 profile 拉取飞书发布表记录的华为云 `tabularis` 镜像。
安装包的 `manifest.yml` 也保留 `frontend.enabled: true` 和 `frontend.basePath: /app/com.ictrek.pgv`，
用于兼容当前仍从应用列表读取 `frontend_enabled/frontend_base_path` 的 VOS“我的应用”打开按钮。
页面由 VOS HTTPS 网关代理到：

```text
https://<vos-host>:1180/app/com.ictrek.pgv/
```

如果通过外部端口映射访问 VOS 网关，也必须使用该网关端口对应的 HTTPS 地址。
直接使用 `http://<vos-host>:1180/app/com.ictrek.pgv/` 会返回平台 404。

宿主机调试端口（页面登录仍需由 VOS 侧边栏注入登录桥接）：

```text
http://<vos-host>:25433/app/com.ictrek.pgv/
```

Tabularis 自动打开以下 PostgreSQL 连接，以及共享 Redis 的 DB 0：

```text
postgres://postgres:<VOS_POSTGRES_PASSWORD>@pgv:5432/postgres
```

可通过 `PGV_VIEWER_PORT` 修改访问端口，通过 `PGV_VIEWER_DB_NAME` 修改默认打开的数据库。
PGV 超级用户密码复用当前 VOS 主机注入的 `VOS_POSTGRES_PASSWORD`，安装时无需单独设置；数据浏览器使用同一密码连接。业务应用应使用各自的普通数据库用户。

## 共享 Redis

PGV 同时提供独立 Redis，供 HybRAG 和其他 VOS 应用显式接入：

```text
REDIS_ADDR=pgv-redis:6379
REDIS_PASSWORD=<当前 VOS 注入的 VOS_REDIS_PASSWORD>
REDIS_DB=<为应用分配的 0–15 数据库编号>
REDIS_PREFIX=<应用专属前缀，例如 hybrag:>
```

仅在 `vos_default` 网络内提供服务，不映射宿主机端口；网络别名为
`pgv-redis` / `ictrek-pgv-redis`，不注册 `redis` 或 `hybrag-redis`。
密码复用 VOS 注入的 `VOS_REDIS_PASSWORD`，缺失时拒绝启动，不使用无密码回退。
数据存放在 `${VOS_APP_STORAGE_PATH}/redis`，开启 AOF（每秒同步），使用
`noeviction`，避免缓存淘汰静默删除任务队列或流记录。
不同应用应使用不同 DB 编号和键前缀；这些仅用于命名隔离，不是访问控制。

复用 HybRAG 已使用的华为云基础镜像：AMD 为 `ictrek/redis:7.0-alpine`，
ARM 为 `ictrek-arm/redis:7.0-alpine`，打包脚本写入对应 `REDIS_*_IMAGE`。
现有 HybRAG 安装仍固定连接自己的 `hybrag-redis`；切换时需在 HybRAG 侧修改
`REDIS_ADDR` 并处理旧队列/会话数据，确认共享实例健康后再停用旧 Redis。
本改动不自动迁移或切换已有应用。

## WeKnora 配置

```text
DB_HOST=ictrek-pgv
DB_PORT=5432
DB_USER=weknora
DB_PASSWORD=weknora
DB_NAME=WeKnora
RETRIEVE_DRIVER=postgres
```

初始化会在 WeKnora 数据库中执行 `CREATE EXTENSION vector;`，并创建
`pg_trgm`。如果镜像提供 `pg_search`，也会创建该扩展。

PGV 会使用 Postgres 超级用户维护 WeKnora 数据库权限：数据库 owner、`public`
schema、已有表/序列/函数和默认对象权限都会授给 `WEKNORA_DB_USER`。`pg_search`
扩展的创建和升级也由 PGV 侧执行；WeKnora/HybRAG 普通运行用户只负责业务表迁移，
不需要拥有 `ALTER EXTENSION pg_search UPDATE` 权限。

## Immich 配置

```text
DB_HOSTNAME=ictrek-pgv
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=vectorchord
```

默认镜像由打包脚本从飞书发布表读取 `pgv` 最新 tag 后写入：

```text
swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:<profile>_<pg-major>_YYYYMMDD
```

它满足 Immich 当前检查的扩展范围：

```text
VectorChord/vchord: >=0.3 <2
pgvecto.rs/vectors: >=0.2 <0.4
pgvector/vector: >=0.5 <1
```

PGV 使用 PostgreSQL 17 和 `pg_search 0.25.11`，默认设置
`shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so`。ARMv8.0/BM1688
及 64 KiB 页系统必须先在对应设备上通过运行测试，再升级已安装实例。

## Nowen Video 配置

```text
NOWEN_DATABASE_HOST=pgv
NOWEN_DATABASE_PORT=5432
NOWEN_DATABASE_USER=nowen
NOWEN_DATABASE_PASSWORD=nowen_password
NOWEN_DATABASE_DBNAME=nowen_video
```

`NOWEN_DATABASE_HOST` 用 `pgv`（`vos_default` 网络别名 `pgv` / `ictrek-pgv` /
`shared-pgv` 三者等价，均指向本服务）。nowen-video 为 PostgreSQL-only 应用，
PGV 首次启动时由 provision 脚本自动创建 `nowen` 角色（非超级用户）、
`nowen_video` 数据库，并启用 `uuid-ossp`、`vector`（必需）、`pg_trgm` 扩展，
随后将库与 `public` schema 的所有权和默认权限授予 `nowen`。nowen 应用侧
仅负责业务表迁移，不需要超级用户权限。

Nowen 的 PGV 侧凭据可通过服务环境变量 `NOWEN_DB_USER`、`NOWEN_DB_PASSWORD`、
`NOWEN_DB_NAME` 覆盖；当前安装表单尚未单独列出这些字段。Nowen 应用侧对应
`NOWEN_DATABASE_USER`、`NOWEN_DATABASE_PASSWORD`、`NOWEN_DATABASE_DBNAME`。
provision 每次启动都会对齐密码和授权，修改时需同步两侧配置。

## 数据持久化

Postgres 数据存储在：

```text
${VOS_APP_STORAGE_PATH}/data
```

PGV 配置目录映射到：

```text
${VOS_APP_STORAGE_PATH}/config
```

这两个目录由 VOS 在应用私有存储下自动创建，不在安装 UI 中单独配置。

## PostgreSQL 17 数据迁移与 BM25 维护

在 VOS 中更新 PGV 即可。PGV 启动前会自动识别现有数据：新安装直接初始化
PostgreSQL 17，已有 PG17 直接启动；检测到 PG16 时，先在应用私有存储中备份，
再恢复到独立的 PG17 目录并执行预置验证，成功后才启动新数据库。
迁移失败会阻止新库启动，原 PG16 数据仍留在 `data`，重试安装会重新迁移。
若旧库异常退出并遗留运行标记，需由管理员确认旧库已停止并恢复后再重试。
旧库和受保护的逻辑备份会保留在应用私有存储中。用户无需连接终端或执行 SQL。
PGV provision 会校验 `pg_search 0.25.11`，并一次性重建旧 BM25 索引。
该过程会造成 PGV 暂时不可用；建议在低使用量时更新。技术细节见 PGV 仓库的
`PG17-MIGRATION.md`。

AI Album 默认继续使用自己的 PostgreSQL；其数据库是否改接 PGV 是独立的配置选择。
PG17 接受新写入后，旧 PG16 备份不能直接代替当前数据。

## Tabularis 自动连接

从 VOS 侧边栏打开 PGV，使用 VOS admin 账户自动登录。Tabularis 在启动时
自动创建或更新 `PGV PostgreSQL`（`pgv:5432`）和 `PGV Redis`
（`pgv-redis:6379`）连接，无需手填主机和密码。原 PGV 数据库、用户、
宿主机端口与别名保持不变；Redis 也不占用其他应用的别名。
连接设置和加密密钥保存在 `${VOS_APP_STORAGE_PATH}/viewer`，重启和升级时保留。
共享数据库管理页仅向经服务端验证的 VOS admin 账户开放。

## 源码与构建

源码统一维护在 [ictrektech/tabularis](https://github.com/ictrektech/tabularis)，
VAI 路径为 `apps/tabularis`，原 PGV 构建与迁移源码位于 `pgv/`。
PGV 与 Tabularis 使用同一套 VOS 打包和发布流程，数据库镜像可复用已发布版本。
内置 PostgreSQL 和 Redis 驱动不依赖在线插件目录；可在设置中手动刷新可选插件。
