# PGV · Tabularis

PGV combines PostgreSQL 17, shared Redis and the Tabularis database workspace.
Open PGV from the VOS sidebar as the VOS admin: PostgreSQL and Redis open
automatically without entering database credentials. The workspace opens directly,
without the community promotion dialog on startup. Use SQL queries, browse
tables and inspect Redis keys. The existing application ID, PostgreSQL endpoints,
host ports, application databases, roles and storage paths remain compatible.

Updates from older PGV releases, including 0.0.33, detect the actual PostgreSQL
major and installed extensions. PG16 data is exported and restored privately
before switching to PG17; the original PG16 directory and backups are retained.
The migration image includes both majors' PostGIS libraries. No terminal access
is required for app users. Failed migrations leave PG16 active; zero-byte and
`.partial` files are not valid backups.
Administrators can use the included `recover-pg16.sh` to take an independent
offline backup and run the same migration flow after an installation failure.

This app provides a shared Postgres service on the `vos_default` Docker network
and provisions separate databases, users, and extensions for WeKnora, Immich, and Nowen Video.

The interface follows the VOS language on startup and live language changes.
The Discord promotion entry is hidden. A blue/cyan voxel V identifies PGV in both
the workspace and the VOS app list. The light-blue Production banner identifies the shared
business database connection; it is not an error.

## Network Address

Containers on `vos_default` should connect to:

```text
pgv:5432
```

For compatibility with older apps, `shared-pgv:5432` is still kept. Do not use
bare `postgres:5432`; it can resolve to the VOS platform database or another
app's Postgres service.

The app publishes Postgres on host port `25432` by default. Containers on
`vos_default` should still prefer `pgv:5432`; the host port is for
debugging or clients outside the Docker network.

## Data Viewer

The app includes the Tabularis data viewer for browsing databases, tables, and
rows. After installation, `routers.yml` registers a standalone `PGV`
top-level page in the VOS sidebar. The
viewer pulls the architecture-specific `tabularis` image recorded in Feishu for
the selected installation profile. The page
is proxied by the VOS HTTPS gateway at:

```text
https://<vos-host>:1180/app/com.ictrek.pgv/
```

When VOS is reached through an external port mapping, use the HTTPS URL for that
gateway port. Direct `http://<vos-host>:1180/app/com.ictrek.pgv/` requests return
the platform 404 response.

Direct host-port debugging URL (page login still requires the VOS sidebar bridge):

```text
http://<vos-host>:25433/app/com.ictrek.pgv/
```

Tabularis automatically opens this PostgreSQL connection and shared Redis DB 0:

```text
postgres://postgres:<VOS_POSTGRES_PASSWORD>@pgv:5432/postgres
```

Use `PGV_VIEWER_PORT` to change the host port and `PGV_VIEWER_DB_NAME` to change
the default database. PGV uses the VOS host's injected `VOS_POSTGRES_PASSWORD`
for its superuser; there is no separate password option during installation.
The viewer verifies the VOS admin account through OIDC; saved database secrets remain on the server. Applications should use dedicated ordinary
database roles.

## Shared Redis

PGV also provides a dedicated Redis for HybRAG and other VOS apps to opt into:

```text
REDIS_ADDR=pgv-redis:6379
REDIS_PASSWORD=<the current VOS-injected VOS_REDIS_PASSWORD>
REDIS_DB=<an application-assigned database number from 0–15>
REDIS_PREFIX=<an application-specific prefix, e.g. hybrag:>
```

It is available only on `vos_default`, without a published host port. Its aliases
are `pgv-redis` / `ictrek-pgv-redis`; it never registers `redis` or `hybrag-redis`.
Authentication requires the VOS-injected `VOS_REDIS_PASSWORD`; startup fails if
it is missing. Data lives in `${VOS_APP_STORAGE_PATH}/redis`, with AOF enabled
and synced every second. The `noeviction` policy avoids silently evicting queue
or stream records. Assign separate DB numbers and key prefixes to each app;
these provide naming separation, not access control.

Packaging reuses HybRAG's published Huawei Cloud base images: `ictrek/redis:7.0-alpine`
for AMD and `ictrek-arm/redis:7.0-alpine` for ARM, via `REDIS_*_IMAGE`.
Existing HybRAG installations still hard-code `hybrag-redis`. Switching requires
a HybRAG-side `REDIS_ADDR` change and a plan for existing queue/session data.
Check shared Redis health before disabling the old instance. This change does
not automatically migrate or switch existing applications.

## WeKnora

```text
DB_HOST=ictrek-pgv
DB_PORT=5432
DB_USER=weknora
DB_PASSWORD=weknora
DB_NAME=WeKnora
RETRIEVE_DRIVER=postgres
```

The provisioner runs `CREATE EXTENSION vector;` in the WeKnora database and also
creates `pg_trgm`. It creates `pg_search` when the selected image provides it.

PGV maintains WeKnora database privileges with the Postgres superuser: the
database owner, `public` schema, existing tables/sequences/functions, and
default object privileges are granted to `WEKNORA_DB_USER`. `pg_search` creation
and validated upgrades are handled by PGV; the WeKnora/HybRAG runtime user only
runs application migrations and does not need `ALTER EXTENSION pg_search UPDATE`
privileges.

## Immich

```text
DB_HOSTNAME=ictrek-pgv
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=vectorchord
```

The default image is resolved from the latest `pgv` tag in the Feishu release
spreadsheet by the package script:

```text
swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:<profile>_<pg-major>_YYYYMMDD
```

It matches Immich's checked extension ranges:

```text
VectorChord/vchord: >=0.3 <2
pgvecto.rs/vectors: >=0.2 <0.4
pgvector/vector: >=0.5 <1
```

PGV uses PostgreSQL 17 and `pg_search 0.25.11`, with
`shared_preload_libraries=pg_search,pg_cron,vchord.so,vectors.so`. Verify the
ARMv8.0/BM1688 and 64 KiB-page hosts directly before upgrading them.

## Nowen Video

```text
NOWEN_DATABASE_HOST=pgv
NOWEN_DATABASE_PORT=5432
NOWEN_DATABASE_USER=nowen
NOWEN_DATABASE_PASSWORD=nowen_password
NOWEN_DATABASE_DBNAME=nowen_video
```

`NOWEN_DATABASE_HOST` uses `pgv` (the `vos_default` aliases `pgv` /
`ictrek-pgv` / `shared-pgv` are equivalent and all resolve to this service).
nowen-video is PostgreSQL-only; on first start the provisioner creates the
`nowen` role (non-superuser) and `nowen_video` database, enables the
`uuid-ossp`, `vector` (required) and `pg_trgm` extensions, then grants the
database and `public` schema ownership plus default privileges to `nowen`. The
nowen runtime user only runs application migrations and does not need superuser
privileges.

Credentials can be overridden in the VOS install UI (`NOWEN_DATABASE_USER` /
`NOWEN_DATABASE_PASSWORD` / `NOWEN_DATABASE_DBNAME`); the provisioner
`ALTER ROLE`s the password and re-grants on every start, so overrides take
effect after the next pgv restart.

## Persistence

Postgres data is stored in:

```text
${VOS_APP_STORAGE_PATH}/data
```

PGV configuration is mounted from:

```text
${VOS_APP_STORAGE_PATH}/config
```

VOS creates both directories below the private application storage root; they are not separate install-form settings.

## PostgreSQL 17 migration and BM25 maintenance

Update PGV in VOS. Before the database starts, PGV detects the existing data:
a new installation initializes PostgreSQL 17, an existing PG17 cluster starts
normally, and a PG16 cluster is backed up and restored into an isolated PG17
directory. Provisioning is verified before the new database starts. On failure,
the original PG16 data remains at `data`, the new database stays stopped, and
retrying the installation repeats the migration. The old cluster and protected
logical dumps remain in the app's private storage. App users do not need a
terminal or SQL access. If an unclean old-server exit leaves a running marker,
an administrator must confirm that PG16 has stopped and recover it before a
retry. PGV provisioning checks `pg_search 0.25.11` and
rebuilds the legacy BM25 index once. PGV is temporarily unavailable during
the upgrade, so choose a low-usage time. See `PG17-MIGRATION.md` in the PGV
repository for technical details.

AI Album retains its own PostgreSQL by default; moving its database to PGV is
a separate configuration choice. After PG17 accepts new writes, the old PG16
backup cannot replace the current data directly.

## Automatic Tabularis connections

Open PGV in the VOS sidebar as the VOS admin account. Startup creates or updates
`PGV PostgreSQL` (`pgv:5432`) and `PGV Redis` (`pgv-redis:6379`) using the existing
VOS-injected credentials. Host ports, aliases, databases, roles and migration
paths are unchanged. Settings and encrypted credentials persist in
`${VOS_APP_STORAGE_PATH}/viewer`. The shared database administration workspace
is available only to the server-verified VOS admin account.

## Source and builds

The unified source lives in [ictrektech/tabularis](https://github.com/ictrektech/tabularis)
at `apps/tabularis` in VAI. Original PGV build and migration sources live in `pgv/`.
PGV and Tabularis share one VOS packaging and release flow; published database
images can be reused. Bundled PostgreSQL and Redis drivers work without the online
plugin registry. Optional plugin updates can be refreshed manually in Settings.
