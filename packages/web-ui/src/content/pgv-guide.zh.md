# 接入 PGV

PGV 提供 PostgreSQL 17（包含向量、搜索等扩展）和独立共享 Redis。数据库连接器用于查看和管理数据；本页说明其他 VOS 应用如何接入。左侧的完整文档库保留用户说明、构建发布、迁移恢复、部署验证和所有安装配置，均随当前版本离线提供。

先在 VOS 安装并启动 `com.ictrek.pgv`，按设备架构选择一个 profile：`amd` 或 `arm`。接入应用的安装包应声明对 PGV 的依赖；打包时从最新已发布版本解析依赖，不写猜测版本。数据库服务和 provision 成功后再启用业务应用。

## 1. 地址和连接方式

| 服务 | 同一 `vos_default` 网络 | 宿主机访问 | 说明 |
| --- | --- | --- | --- |
| PostgreSQL | `pgv:5432` | `<VOS主机>:25432` | `ictrek-pgv`、`shared-pgv` 是兼容别名；宿主机端口可由 `ICTREK_PGV_PORT` 覆盖 |
| Redis | `pgv-redis:6379` | 不发布宿主机端口 | 另一个别名为 `ictrek-pgv-redis` |
| 数据库连接器 | VOS → PGV → 数据库连接器 | 调试端口 `25433`，可由 `PGV_VIEWER_PORT` 覆盖 | 通过 VOS HTTPS 网关及管理员登录桥接使用 |

其他应用的容器必须加入外部网络 `vos_default`。不要填写 `localhost`（它指向应用容器自身），也不要使用裸 `postgres` 或 `redis`，以免连到平台或其他应用的数据库。PGV 不替换 VOS 自带的 Postgres，不注册 `hybrag-redis`。

```yaml
services:
  my-app:
    # 填写应用实际镜像与环境变量
    networks: [vos_default]
networks:
  vos_default:
    external: true
```

PostgreSQL 通用连接串：

```text
postgresql://myapp:<独立应用密码>@pgv:5432/myapp
```

密码放进 URI 时必须进行 URL 编码。应用也可以分别配置 host、port、user、password 和 database，避免编码歧义。内网示例不启用 TLS；容器网络外连接应按部署网络与访问策略配置。

## 2. 初始账户、密码和默认数据库

以下是**软件初始值**，不是当前安装的实时凭据。在安装配置中覆盖后，以覆盖值为准；不要把这些业务默认密码误认为 VOS 登录密码。

| 用途 | 数据库 | 用户名 | 初始密码／来源 | 权限 |
| --- | --- | --- | --- | --- |
| PGV 管理 | `postgres` | `postgres`（可由 `POSTGRES_SUPERUSER` 覆盖） | VOS 注入的 `VOS_POSTGRES_PASSWORD`，没有另一套固定密码 | 超级用户，仅管理使用 |
| WeKnora / HybRAG | `WeKnora`，大小写敏感 | `weknora` | `weknora` | 普通用户、该库 owner |
| Immich | `immich` | `immich` | `immich` | 默认超级用户，可用 `IMMICH_DB_SUPERUSER` 调整 |
| Nowen Video | `nowen_video` | `nowen` | `nowen_password` | 普通用户、该库 owner |
| Redis | 默认使用 DB `0`；可分配 `0–15` | 无需显式用户名；ACL 用户为 `default` | VOS 注入的 `VOS_REDIS_PASSWORD`，没有独立固定密码 | 实例共享访问 |

`template0`、`template1` 是 PostgreSQL 系统模板，不是业务数据库。Redis 的 DB 编号是预先存在的逻辑空间，不需要 `CREATE DATABASE`。

需要 VOS 注入的密码时，由管理员从当前主机的受保护配置提供给接入应用；本指南不会读取或显示主机实际密码。连接器已通过注入的凭据自动打开 PG 和 Redis，管理员无需手填。缺少 Redis 密码时服务拒绝启动，不回退到无密码模式。

PGV 每次 provision 都会创建或补齐预置库、角色、扩展和权限，并按 `WEKNORA_DB_*`、`IMMICH_DB_*`、`NOWEN_DB_*` 配置对齐这些角色的密码。修改预置账户应同时修改 PGV 安装配置和业务应用配置，避免只用 SQL 改密码后又被 provision 覆盖。应用自建角色（例如既有 V-Scheduler 角色）保留自己的凭据。

## 3. 为新应用创建独立 PostgreSQL 数据库

不要让新应用共用预置业务库，也不要把 `postgres` 超管账户作为应用运行账户。

1. 在“数据库连接器”中使用自动打开的 `PGV PostgreSQL` 管理连接，连接到 `postgres` 库。
2. 把下列示例用户名、数据库名和占位密码替换为应用自己的值。**分次执行**，`CREATE DATABASE` 不可放在事务中。

```sql
CREATE ROLE myapp LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  PASSWORD 'replace_with_a_unique_password';
```

```sql
CREATE DATABASE myapp OWNER myapp;
```

3. 在连接器中新增到 `myapp` 库的 PostgreSQL 连接，先使用管理员身份完成需要的扩展配置；连接地址仍为 `pgv:5432`。如果使用 psql，改用 `-d myapp`；`\connect` 是 psql 命令，不能直接粘贴到普通 SQL 编辑器。

```sql
-- 在新建的 myapp 库中执行；按实际需求选择扩展。
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
GRANT USAGE, CREATE ON SCHEMA public TO myapp;
```

4. 再用应用自己的 `myapp` 用户连接 `myapp` 库，运行其 ORM / schema 迁移。角色与数据库创建命令仅在首次执行，名称已存在时先检查，不要删除既有库。

```text
DB_HOST=pgv
DB_PORT=5432
DB_USER=myapp
DB_PASSWORD=<独立应用密码>
DB_NAME=myapp
```

使用哪个环境变量名由接入应用决定；上述通用变量不会替应用自动修改配置。验证连接：

```sql
SELECT current_database(), current_user, version();
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

默认连接器打开 `postgres`；可用 `PGV_VIEWER_DB_NAME` 改为已存在的业务库。修改默认打开的库不会自动建库。

## 4. 已支持应用的配置

### WeKnora / HybRAG

```text
DB_HOST=ictrek-pgv
DB_PORT=5432
DB_USER=weknora
DB_PASSWORD=weknora
DB_NAME=WeKnora
RETRIEVE_DRIVER=postgres
```

使用覆盖过的用户名、密码、库名时同步替换。PGV 为该库创建 `uuid-ossp`、`vector`、`pg_trgm`，镜像提供时创建 `pg_search`；扩展升级由 PGV 超管负责，业务用户不需要 `ALTER EXTENSION` 权限。HybRAG 仍保留自己的 Redis，改接共享 Redis 需单独迁移数据。

### Immich / AI Album

```text
DB_HOSTNAME=ictrek-pgv
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=vectorchord
```

预建扩展：`uuid-ossp`、`unaccent`、`cube`、`earthdistance`、`pg_trgm`、`vector`、`vchord`、`vectors`。Immich 默认角色具备超级权限，以支持备份恢复与扩展管理。AI Album 默认仍使用自己的 PostgreSQL；现有数据迁移到 PGV 的停机、PG14 导出恢复及资源验证步骤见“PG16 → PG17 与恢复”完整文档的 AI Album 章节，不能只改地址就认为迁移完成。

### Nowen Video

```text
NOWEN_DATABASE_HOST=pgv
NOWEN_DATABASE_PORT=5432
NOWEN_DATABASE_USER=nowen
NOWEN_DATABASE_PASSWORD=nowen_password
NOWEN_DATABASE_DBNAME=nowen_video
```


Nowen 的 PGV 侧覆盖变量是 `NOWEN_DB_NAME`、`NOWEN_DB_USER`、`NOWEN_DB_PASSWORD`；当前安装表单没有单独列出这些字段，需在 PGV 服务环境中配置，并与 Nowen 应用侧 `NOWEN_DATABASE_*` 同步。

预建 `uuid-ossp`、`vector`、`pg_trgm`；Nowen 使用普通用户运行业务表迁移。

## 5. 接入共享 Redis

```text
REDIS_ADDR=pgv-redis:6379
REDIS_PASSWORD=<当前 VOS_REDIS_PASSWORD>
REDIS_DB=<为应用分配的 0–15 编号>
REDIS_PREFIX=myapp:
```

在 VOS 应用的 Compose 中，可以直接引用平台注入变量，无需把主机密码写进源码或文档：

```yaml
environment:
  REDIS_ADDR: pgv-redis:6379
  REDIS_PASSWORD: ${VOS_REDIS_PASSWORD:?VOS_REDIS_PASSWORD is required}
  REDIS_DB: "1"
  REDIS_PREFIX: "myapp:"
```

URI 形式（密码应 URL 编码；客户端不要求用户名时可使用第二种）：

```text
redis://default:<VOS_REDIS_PASSWORD>@pgv-redis:6379/0
redis://:<VOS_REDIS_PASSWORD>@pgv-redis:6379/0
```

不同应用分配不同 DB 编号，并为键设置独立前缀；DB / 前缀只是命名隔离，不是访问控制。实际变量名与前缀是否自动附加由客户端实现决定。Redis 无需 SQL 建库，选择 DB 后写入键即可使用。Redis Cluster 客户端若要求集群能力，不能直接当作本服务的接入方式。

本实例开启 AOF、每秒同步，采用 `noeviction`，以免缓存淘汰删除任务队列或流记录；存储不足等写入失败仍需由业务应用处理。不要在共享实例中运行 `FLUSHALL`，也不要对其他应用的 DB 运行 `FLUSHDB`。在连接器选择 Redis 连接可使用驱动提供的 SQL 视图查看键：

```sql
SELECT * FROM keys;
```

这是 Tabularis Redis 驱动的查询方式，原生 Redis 客户端仍使用 Redis 命令。连通性检查可使用原生客户端的 `PING` 和 `SELECT <编号>`。

HybRAG 现有安装连接 `hybrag-redis`。切换到 `pgv-redis` 前，需暂停依赖 Redis 的任务，迁移旧队列／会话数据，更新 `REDIS_ADDR` 与密码，确认新实例和应用健康后再停用旧实例；PGV 安装不会自动切换其他应用。

## 6. 持久化、升级和排障

| 路径（相对 `VOS_APP_STORAGE_PATH`） | 内容 |
| --- | --- |
| `data` | 原有 PostgreSQL 数据目录 |
| `config` | PostgreSQL 配置 |
| `redis` | Redis AOF 数据 |
| `viewer` | 连接器设置、加密凭据及密钥；备份时一起保存 |
| `data-pg16-backup`、`pgv-migration-backups` | PG16 → PG17 升级保留的旧目录与受保护逻辑备份 |

- 新装直接初始化 PG17；已有 PG17 直接启动；PG16 按实际数据版本自动备份并恢复到独立 PG17 后验证切换。失败时保留旧数据并停止新库，不能把 `.partial` 或零字节文件当作备份。
- PG17 开始写入后，旧 PG16 目录不能直接作为当前数据回滚。完整迁移、PostGIS / pg_ivm、BM25 重建、独立离线备份和 `recover-pg16.sh` 的使用均在文档库中保留。
- 预置账户鉴权失败：核对 PGV 安装配置是否覆盖默认密码，以及 provision 是否成功；容器连接失败：确认 `vos_default`、服务别名和内部端口；Redis 鉴权失败：确认与当前主机注入密码一致。
- 超管维护可刷新预置库的权限和扩展，不删除现有业务数据。V-Scheduler 等自建库由应用自己维护，不会因为安装 PGV 就自动创建。
- 当前 PG17 镜像包含搜索、向量与空间扩展；具体版本、ARM / BM1688 / 64 KiB 设备验证边界，以及历史门禁结果均保留在完整文档，不把构建成功等同于所有硬件验证。

## 完整文档库

左侧可继续阅读随本版本打包的完整用户说明、PGV 镜像与发布说明、PG16 → PG17 迁移恢复、VOS 部署和完整安装配置。原文保留其原有语言与历史验证范围；历史 PG16 操作不能直接套用到当前 PG17。仓库中的脚本链接指向源码，网页展示不会执行命令或修改数据库。
