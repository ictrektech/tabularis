> This directory preserves the PGV image sources and migration verification scripts.
> The unified application package lives at `../ictrek.app`; `ictrek.app` here is
> a compatibility symlink for existing verification scripts. Build both images
> from the repository root; see [VOS deployment](../VOS.md).

# PGV VOS 应用打包说明

本目录包含 VOS app `com.ictrek.pgv` 的安装包模板和 PGV 镜像构建脚本。PGV 是一个共享 Postgres + vector extension 基础服务，用于给同在 `vos_default` 网络中的 WeKnora、Immich、Nowen Video 等应用复用数据库能力。
发布流程以 `update_version.sh` 触发的 GitHub Actions 为准。

它不会替换或修改 VOS 平台自带的 `postgres` 容器。默认使用独立服务名、网络别名和宿主机端口，禁止在 `vos_default` 中暴露裸 `postgres` 名称，避免与平台已有 `postgres:5432` 冲突。

## 预置数据库与应用接入

PGV 启动时由 provision 脚本（`ictrek.app/src/init/provision.sh`）自动创建下列数据库、角色与扩展。`vos_default` 网络内的容器统一用别名 `pgv:5432`（`pgv` / `ictrek-pgv` / `shared-pgv` 三者等价）连接。凭据可通过相应环境变量覆盖，当前安装表单未列出的字段需在服务环境中配置，provision 每次启动都会 `ALTER ROLE` 对齐密码并重建授权。

| 应用 | 主机 | 端口 | 用户 | 密码 | 数据库 | 角色 | 扩展 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| WeKnora | `ictrek-pgv` | 5432 | `weknora` | `weknora` | `WeKnora` | 普通用户 | `uuid-ossp`、`vector`（必需）、`pg_trgm`、`pg_search`（镜像提供时） |
| Immich | `ictrek-pgv` | 5432 | `immich` | `immich` | `immich` | 超级用户 | `uuid-ossp`、`unaccent`、`cube`、`earthdistance`、`pg_trgm`、`vector`（必需）、`vchord`、`vectors` |
| Nowen Video | `pgv` | 5432 | `nowen` | `nowen_password` | `nowen_video` | 普通用户 | `uuid-ossp`、`vector`（必需）、`pg_trgm` |

对应应用侧环境变量：

```text
# WeKnora
DB_HOST=ictrek-pgv          DB_PORT=5432   DB_USER=weknora
DB_PASSWORD=weknora         DB_NAME=WeKnora

# Immich
DB_HOSTNAME=ictrek-pgv      DB_PORT=5432   DB_USERNAME=immich
DB_PASSWORD=immich          DB_DATABASE_NAME=immich

# Nowen Video
NOWEN_DATABASE_HOST=pgv     NOWEN_DATABASE_PORT=5432   NOWEN_DATABASE_USER=nowen
NOWEN_DATABASE_PASSWORD=nowen_password                 NOWEN_DATABASE_DBNAME=nowen_video
```

超管账号（仅维护用，不要给应用）：用户 `postgres`，密码复用当前 VOS 主机注入的 `VOS_POSTGRES_PASSWORD`，安装表单不再单独设置。各应用只应使用自己的普通用户连接库。

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

## 打包

正式发布不要在本地读取飞书并打包。发布入口是 `ictrek.app/scripts/update_version.sh`：它只更新 `VERSION`、提交 release commit、推送 `vos-pgv-v${VERSION}` 触发 tag；GitHub Actions 收到 tag 后才会读取飞书组件版本、生成 pull 包并更新 GitHub release。

本地 `package.sh` 只用于调试模板或手动验证。它不会递增或写回 `VERSION`；未设置 `PACKAGE_VERSION` 时读取当前 `ictrek.app/VERSION`，CI 会显式传入 tag 中解析出的 `PACKAGE_VERSION`。

```bash
cd apps/tabularis/ictrek.app
./scripts/package.sh
```

脚本只生成一个 pull 模式安装包：

```text
dist/pgv_${VERSION}_pull.tar
```

安装包包含 PGV 的 `icon.png` 应用图标和一个 `docker-compose.yml`，其中包含 `arm` 和 `amd` 两个 Docker Compose profile。打包脚本会优先读取 `~/.feishu.components.json`，若文件不存在或读取失败则回退到 `~/.feishu.json`，分别从对应 sheet 读取 `pgv` 镜像最新版本，并写入包内 `.env`。

不再通过 `--platform` 生成多个 tar 包，也不再生成包含 `assets/` 镜像归档的 local 包。

## Profiles

| profile | 飞书 sheet | 适用平台 |
| --- | --- | --- |
| `arm` | `ARM_without_cuda`（所有 ARM 发布表统一） | ARM / L4T 类设备 |
| `amd` | `AMD_with_cuda` | x86_64 / AMD64 类设备 |

安装时由 VOS 指定其中一个 profile。手动验证 Compose 文件时也必须只启用一个 profile：

```bash
docker compose --profile amd config
docker compose --profile arm config
```

## PostgreSQL 17 镜像构建

从 0.0.33 等 PG16 版本安装/升级时，安装器读取 `data/PG_VERSION` 和各库扩展，
自动导出、恢复到 PG17 后切换目录。迁移镜像必须同时提供 PG16/PG17 PostGIS
及依赖，覆盖 geometry/geography、raster、topology 和 SFCGAL；不能只复制较新
PG16 镜像中的扩展目录，也不能把 PG17 库用于 PG16。`pg_ivm` 同时补齐，并按
定义恢复增量视图的维护元数据。构建会用 0.0.33 原镜像验证空间数据和增量更新。
构建凭据文件可通过 `FEISHU_CONFIG_FILE` 指定。完整路径、失败重试和管理员兜底脚本见
[PG17-MIGRATION.md](PG17-MIGRATION.md)。

PGV 基于 ParadeDB `v0.25.11-pg17`，并安装 PG17 对应的 VectorChord 0.4.3
和 pgvecto.rs 0.3.0（`vectors` schema）。基镜像分别镜像到华为云
`ictrek/paradedb:amd64_0.25.11-pg17` 和 `ictrek/paradedb:arm64_0.25.11-pg17`。
ARM 构建使用上游基础镜像及 VectorChord，并使用
`scripts/build_vectors_pg17_arm.sh` 从固定源码构建去除 jemalloc 的 PG17
`vectors 0.3.0` 包；发布前仍须在目标 ARM CPU 和页大小上验证，尤其是
ARMv8.0/BM1688 和 64 KiB。旧 PG16 的便携扩展脚本仅用于旧镜像。

统一在可用的 ARM 构建机上构建，不在目标 VOS 主机上构建：

```bash
cd apps/tabularis/pgv
./build_image.sh arm --sheet ARM_without_cuda --build-only
```

当前 ARM 仅允许 `--build-only` 候选构建；64 KiB 与 BM1688 门禁通过前，
`build_image.sh` 默认拒绝发布。若已明确授权先发布、后补特殊硬件实测，可设置
`PGV_RELEASE_WITHOUT_PHYSICAL_ARM=1`；这不代表对应设备验证通过。发布前，在 4 KiB 与 64 KiB 主机分别验证完整 ARM 默认预加载、
五个扩展创建、BM25 查询及 PG16 数据迁移。
在运行 `update_version.sh` 前，必须在 `tcnas`（AINAS/BM1688）、
`tcarm`（192.168.1.4，64 KiB 页）和 `tc192`（192.168.1.192）分别运行：

```bash
./scripts/verify_arm_runtime.sh --image swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:arm_17_YYYYMMDD
./scripts/verify_pg17_migration.sh --image swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:arm_17_YYYYMMDD --old-image swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:arm_16_20261012
./scripts/verify_pg17_v_scheduler.sh --image swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:arm_17_YYYYMMDD --scheduler-image <对应架构的 V-Scheduler 镜像>
```

测试脚本强制使用新数据卷；自动升级机制见 [PG17-MIGRATION.md](PG17-MIGRATION.md)。

VOS 用户更新 PGV 时，包内一次性迁移服务会先检查 `data/PG_VERSION`：
新安装与已有 PG17 直接启动；PG16 自动导出全部数据库、恢复到独立 PG17 目录、
执行 provision 并验证后才切换。失败时旧 `data` 不变，PGV 主库不启动；
可重试错误由用户重新安装触发迁移，无需终端操作；若旧库异常退出并遗留
`postmaster.pid`，迁移会安全停止，需管理员确认旧库已停止并恢复后再重试。
旧 PG16 目录和受保护备份保留。
迁移会保留 V-Scheduler 等应用自有角色的原密码；PGV 管理员密码按当前
`VOS_POSTGRES_PASSWORD` 对齐，PGV 维护的 WeKnora、Immich、Nowen 密码按各自
环境变量对齐。已配置的 V-Scheduler 继续使用原有 `database.env` 凭据。

## 镜像构建

`Dockerfile` 和 `build_image.sh` 位于 `ictrek.app/` 外层，避免把镜像构建过程混入 VOS app 安装包模板。

构建候选镜像：

```bash
cd apps/tabularis/pgv
./build_image.sh amd --build-only
./build_image.sh arm --build-only
```

PG17 的迁移门禁见上文及 [PG17-MIGRATION.md](PG17-MIGRATION.md)。
ARM 发布当前受 64 KiB/BM1688 兼容性门禁阻断。

镜像仓库和 tag 格式：

```text
swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:<profile>_<pg-major>_YYYYMMDD
```


## 版本更新与 Release

推荐通过 `ictrek.app/scripts/update_version.sh` 触发版本更新和 GitHub Actions release。脚本只更新 `VERSION`、提交、打 tag 并 push；真正的 pull 包打包、release notes 生成和 tar 上传由 `.github/workflows/vos-release.yml` 完成。

发布前先提交业务代码改动，保持工作区干净，然后运行：

```bash
./ictrek.app/scripts/update_version.sh patch
```

可选参数为 `patch`、`minor`、`major`，默认是 `patch`。脚本会生成并推送 `vos-pgv-v${VERSION}` 形式的 CI 触发 tag。GitHub Actions 收到 tag 后会：

- 使用 tag 中的版本号作为 `PACKAGE_VERSION` 调用 `package.sh`，生成 `dist/pgv_${VERSION}_pull.tar`。
- 读取 `~/.feishu.components.json` 所需的 GitHub Secrets：`FEISHU_APP_ID`、`FEISHU_APP_SECRET`、`APPSTORE_IP`、`APPSTORE_TOKEN`。飞书表格 ID 为固定公开配置，不是 secret。
- 在 CI 中通过飞书发布表读取 `pgv` 和 `tabularis` 最新镜像 tag；当前不读取其他 VOS app release，因此不需要 `VOS_DEPENDENCY_RELEASE_TOKEN`。
- 查找上一个 VOS release tag，把两个 tag 之间的提交记录写入 release notes。
- 创建标准 SemVer GitHub release tag `v${VERSION}`，标题使用 `v${VERSION}`，并上传 pull 模式 tar 包。`vos-pgv-v${VERSION}` 只用于触发 CI，不作为公开 release tag。

如果 release tag 已存在，应先确认是否是重发同一版本；不要覆盖未知来源的资产。确需补传同一版本产物时再手动使用 `gh release upload --clobber`。

## Installation and viewer

Use the unified VOS package described in [VOS.md](../VOS.md). The app ID remains
`com.ictrek.pgv` and its embedded entry remains `/app/com.ictrek.pgv/`. Tabularis
replaces the former viewer and authenticates the VOS admin through OIDC.
PostgreSQL endpoints, existing databases and migration paths are unchanged.
VOS provisions `data`, `config`, `redis` and `viewer` below `VOS_APP_STORAGE_PATH`.

## 连接方式

同在 `vos_default` 网络中的容器应使用稳定服务别名访问：

```text
postgresql://postgres:<VOS_POSTGRES_PASSWORD>@pgv:5432/postgres
```

兼容旧应用时也可以继续使用 `shared-pgv:5432`。不要使用裸 `postgres:5432`，
避免解析到 VOS 平台或其他应用的 Postgres。

默认预置数据库和用户：

| 用途 | 数据库 | 用户 | 默认密码 |
| --- | --- | --- | --- |
| PGV 管理 | `postgres` | `postgres` | 当前 VOS 主机数据库密码 |
| WeKnora | `WeKnora` | `weknora` | `weknora` |
| Immich | `immich` | `immich` | `immich` |
| Nowen Video | `nowen_video` | `nowen` | `nowen_password` |

PGV provision 容器会用 Postgres 超级用户维护这些数据库：

- 确保 WeKnora 数据库 owner 为 `WEKNORA_DB_USER`。
- 确保 `public` schema、已有表、序列、函数和后续默认对象权限授给 `WEKNORA_DB_USER`。
- 在 WeKnora 数据库中创建 `vector`、`pg_trgm`，如果镜像提供 `pg_search` 也会创建。
- `pg_search` 的创建和升级由 PGV 侧超级用户执行；PG17 镜像要求 0.25.11，失败会阻止 provision 完成；WeKnora/HybRAG 运行用户不需要、也不应该拥有 `ALTER EXTENSION pg_search UPDATE` 权限。
- 确保 Immich 用户为超级用户（Immich 运行时需要），并在其库中创建 `vector`、`vchord`、`vectors` 等扩展。
- 确保 Nowen Video 数据库 owner 为 `nowen`，并在其库中创建 `vector`（必需）、`uuid-ossp`、`pg_trgm`；nowen 运行用户为普通用户，只负责业务表迁移。

如果升级 PGV 后只想刷新已有库的扩展和权限，可以重新运行 PGV app 的 provision 服务；这不会删除 WeKnora、Immich 或 Nowen Video 数据。

宿主机调试端口默认是：

| 服务 | 宿主机端口 | 容器端口 |
| --- | --- | --- |
| Postgres | `25432` | `5432` |
| Tabularis | `25433` | `8081` |

## 路由

`routers.yml` 使用可见 sidebar page 作为入口。新增或修改入口时必须同步检查 `/app/com.ictrek.pgv/` 的 iframe 页面，以及 Compose/Traefik 中的顶层文档重定向。

## 旧版 PostgreSQL 16 / BM25 升级与恢复

以下只记录旧版 PG16 内部从 `pg_search 0.22.2–0.22.5` 升至 0.22.6
的流程；当前 `build_image.sh` 已切换 PG17，不再提供 PG16 发布入口。
PG16 → PG17 需使用上文的逻辑迁移流程。

保留 PG16 数据目录，升级前先备份数据库并停止 HybRAG 的导入、删除和检索。
先升级 PGV 镜像，再运行包内 provision 服务；它以超级用户将 `pg_search`
从 0.22.2–0.22.5 升到 0.22.6，并在同一事务中重建已有的
`public.embeddings_search_idx`。已是 0.22.6 的旧库也会执行一次重建。
完成记录位于 `ictrek_pgv.maintenance`，后续 provision 不重复重建；
尚无 embeddings 表的新库不记录完成，下一次 provision 会补做。
升级或重建失败会回滚事务、保留待修复状态，阻止 provision 报告成功。
不自动降级其他版本，不清空表、不删除数据卷。

普通 `REINDEX` 会阻塞写入；此流程使用 15 秒锁等待和 30 分钟执行上限。
请在维护窗口完成，验证成功后再恢复 HybRAG。镜像回退不能替代扩展回退；
回滚时应从升级前备份恢复到独立 PG16 数据卷。

如完成升级后需要再次修复索引，在已安装的 PGV 包目录中按实际 profile 运行：

```bash
docker compose --profile amd run --rm -e PGV_REBUILD_BM25=true ictrek-pgv-provision-amd
# ARM 使用 --profile arm 和 ictrek-pgv-provision-arm。
```

恢复成功后重试失败文档。

发布门禁使用隔离的新数据卷：

```bash
./scripts/verify_pg_search_upgrade.sh --image <候选镜像> --old-image <同架构旧版PGV镜像>
```

门禁建立 0.22.2 旧库及 10,553 条记录，再用同一个数据卷启动新镜像，验证
扩展升级、索引实际重建、数据保留、重复 provision、显式恢复、删除＋VACUUM、
带过滤条件的 BM25 查询、向量查询和重新写入，以及共享应用的扩展创建。
`build_image.sh --build-only` 只构建并验证候选镜像；正常构建在本机门禁通过后
才推送镜像并更新飞书。ARM 发布前仍需在 BM1688、4 KiB 和 64 KiB 主机执行
运行时门禁。ARM 扩展源码构建入口为 `scripts/build_pg_search_arm.sh`，
使用固定源码快照、通用 ARMv8 编译参数和 ictrek 华为云 PG16 基镜像。

该 ARM 源码构建入口复用构建机已有的 Rust stable 工具链、cargo-pgrx 0.17.0
及 PostgreSQL 16 开发头文件/pg_config。默认缓存为 `~/dev/build/pgsearch-host`，
可用 `PG_SEARCH_TOOLCHAIN_ROOT` 指定同布局缓存；所有编译输出保留在
`~/dev/build/pgsearch-0226`，扩展压缩包复制到 `vendor/arm64/` 后由 Git LFS 管理。
