# Connect applications to PGV

PGV provides PostgreSQL 17 with vector/search extensions and a dedicated shared Redis. Use Database Connector to manage data, and this page to connect other applications. The document library includes the complete user manual, image/release notes, migration/recovery procedures, VOS deployment and every installation setting, bundled offline with this version.

Install and start `com.ictrek.pgv` first, selecting exactly one architecture profile (`amd` or `arm`). Client app packages should declare a PGV dependency resolved from its latest published release, not a guessed version. Start clients after the database and provisioning services succeed.

## 1. Addresses and networking

| Service | Inside `vos_default` | Host access | Notes |
| --- | --- | --- | --- |
| PostgreSQL | `pgv:5432` | `<VOS-host>:25432` | Compatible aliases: `ictrek-pgv`, `shared-pgv`; host port configurable via `ICTREK_PGV_PORT` |
| Redis | `pgv-redis:6379` | No published host port | Alternate alias: `ictrek-pgv-redis` |
| Database Connector | VOS → PGV → Database Connector | Debug port `25433`, configurable via `PGV_VIEWER_PORT` | Use the VOS HTTPS gateway and admin login bridge |

Join the external `vos_default` Docker network. `localhost` addresses the client container, not PGV. Avoid bare `postgres` and `redis` aliases: they can resolve to the platform or another application. PGV does not replace the platform Postgres or register `hybrag-redis`.

```yaml
services:
  my-app:
    # Supply the actual application image and environment.
    networks: [vos_default]
networks:
  vos_default:
    external: true
```

```text
postgresql://myapp:<application-password>@pgv:5432/myapp
```

URL-encode passwords in connection URIs, or pass host/port/user/password/database separately. Internal examples do not enable TLS; configure access outside the container network according to the deployment's network and access policy.

## 2. Initial accounts and databases

These are software defaults, not live credentials. Installation overrides take precedence. Business database defaults are not VOS login credentials.

| Purpose | Database | Username | Initial password / source | Privileges |
| --- | --- | --- | --- | --- |
| PGV administration | `postgres` | `postgres`, overridable with `POSTGRES_SUPERUSER` | VOS-injected `VOS_POSTGRES_PASSWORD`; no separate fixed password | Superuser for administration |
| WeKnora / HybRAG | `WeKnora`, case-sensitive | `weknora` | `weknora` | Ordinary role, database owner |
| Immich | `immich` | `immich` | `immich` | Superuser by default; configurable via `IMMICH_DB_SUPERUSER` |
| Nowen Video | `nowen_video` | `nowen` | `nowen_password` | Ordinary role, database owner |
| Redis | DB `0` by default; allocate from `0–15` | Username optional; ACL user `default` | VOS-injected `VOS_REDIS_PASSWORD`; no separate fixed password | Shared instance access |

`template0` and `template1` are PostgreSQL system templates, not business databases. Redis DB numbers already exist as logical spaces; no SQL database creation is needed.

An administrator supplies the injected passwords to client applications from the host's protected configuration. This page never reads or exposes live host passwords. The connector automatically opens PG and Redis with injected credentials. Redis refuses to start without a password.

Provisioning reconciles predefined databases, roles, extensions and permissions on each run. Passwords follow `WEKNORA_DB_*`, `IMMICH_DB_*` and `NOWEN_DB_*`; update both PGV installation settings and the client configuration. SQL-only password changes to these managed roles can be overwritten. Application-owned roles, including existing V-Scheduler roles, retain their own credentials.

## 3. Create a dedicated PostgreSQL database

Use a separate database and ordinary role for each new application, rather than the admin account or another application's database.

1. Open the managed `PGV PostgreSQL` admin connection to `postgres` in Database Connector.
2. Replace the example names and placeholder password. Execute the statements separately: `CREATE DATABASE` cannot run inside a transaction.

```sql
CREATE ROLE myapp LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  PASSWORD 'replace_with_a_unique_password';
```

```sql
CREATE DATABASE myapp OWNER myapp;
```

3. Add a PostgreSQL admin connection to the new `myapp` database, still at `pgv:5432`, to install required extensions. With psql use `-d myapp`; `\connect` is a psql command, not SQL for the query editor.

```sql
-- Run in the new myapp database; enable only required extensions.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
GRANT USAGE, CREATE ON SCHEMA public TO myapp;
```

4. Connect as `myapp` to `myapp` and run the application's own schema/ORM migrations. Create the role/database only once; inspect existing objects rather than deleting them.

```text
DB_HOST=pgv
DB_PORT=5432
DB_USER=myapp
DB_PASSWORD=<application-password>
DB_NAME=myapp
```

Actual environment variable names depend on the client application. Check connectivity with:

```sql
SELECT current_database(), current_user, version();
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

`PGV_VIEWER_DB_NAME` changes the initially opened database, default `postgres`. It does not create that database.

## 4. Existing application integrations

### WeKnora / HybRAG

```text
DB_HOST=ictrek-pgv
DB_PORT=5432
DB_USER=weknora
DB_PASSWORD=weknora
DB_NAME=WeKnora
RETRIEVE_DRIVER=postgres
```

Replace overridden values accordingly. PGV provisions `uuid-ossp`, `vector`, `pg_trgm` and `pg_search` when available. PGV's administrator handles extension upgrades; the application does not need `ALTER EXTENSION` rights. Existing HybRAG Redis remains separate unless explicitly migrated.

### Immich / AI Album

```text
DB_HOSTNAME=ictrek-pgv
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich
DB_VECTOR_EXTENSION=vectorchord
```

Predefined extensions: `uuid-ossp`, `unaccent`, `cube`, `earthdistance`, `pg_trgm`, `vector`, `vchord`, `vectors`. The Immich role defaults to superuser for backup, restore and extension management. AI Album still uses its own PostgreSQL by default. Its existing database/library must be backed up and migrated, not just pointed to another host; the complete migration document includes PG14 restore and verification details.

### Nowen Video

```text
NOWEN_DATABASE_HOST=pgv
NOWEN_DATABASE_PORT=5432
NOWEN_DATABASE_USER=nowen
NOWEN_DATABASE_PASSWORD=nowen_password
NOWEN_DATABASE_DBNAME=nowen_video
```


PGV-side overrides use `NOWEN_DB_NAME`, `NOWEN_DB_USER` and `NOWEN_DB_PASSWORD`. These are service environment settings, not currently separate installation-form fields; align them with the client's `NOWEN_DATABASE_*` settings.

PGV provisions `uuid-ossp`, `vector` and `pg_trgm`; the ordinary Nowen role handles business-table migrations.

## 5. Shared Redis

```text
REDIS_ADDR=pgv-redis:6379
REDIS_PASSWORD=<current VOS_REDIS_PASSWORD>
REDIS_DB=<allocated number from 0–15>
REDIS_PREFIX=myapp:
```

A VOS app's Compose can reference the injected value without hard-coding the host password:

```yaml
environment:
  REDIS_ADDR: pgv-redis:6379
  REDIS_PASSWORD: ${VOS_REDIS_PASSWORD:?VOS_REDIS_PASSWORD is required}
  REDIS_DB: "1"
  REDIS_PREFIX: "myapp:"
```

URI forms, with a URL-encoded password:

```text
redis://default:<VOS_REDIS_PASSWORD>@pgv-redis:6379/0
redis://:<VOS_REDIS_PASSWORD>@pgv-redis:6379/0
```

Allocate different DB numbers and key prefixes to applications. These provide naming separation, not access control. Variable names and automatic prefix handling depend on the client. Redis needs no SQL database creation: select a DB and write keys. Clients requiring Redis Cluster capabilities cannot use this standalone service as a cluster.

AOF is enabled with a one-second sync policy, and `noeviction` avoids silently evicting queues/streams. Applications must still handle failed writes, including insufficient storage. Do not run `FLUSHALL` on the shared instance or `FLUSHDB` on another application's DB. The connector's Redis driver exposes SQL views:

```sql
SELECT * FROM keys;
```

Native Redis clients continue to use Redis commands such as `PING` and `SELECT <number>`.

Existing HybRAG connects to `hybrag-redis`. Before switching to `pgv-redis`, pause dependent tasks, migrate queue/session data, update the address/password, verify service and application health, then retire the old instance. Installing PGV does not switch other applications automatically.

## 6. Persistence, upgrades and troubleshooting

| Path under `VOS_APP_STORAGE_PATH` | Contents |
| --- | --- |
| `data` | Existing PostgreSQL cluster |
| `config` | PostgreSQL configuration |
| `redis` | Redis AOF data |
| `viewer` | Connector settings, encrypted secrets and key; back these up together |
| `data-pg16-backup`, `pgv-migration-backups` | Retained PG16 cluster and protected logical backups |

- Fresh installs initialize PG17, existing PG17 starts normally, and PG16 is backed up/restored into an isolated PG17 cluster before verified cutover. Failures preserve old data and stop the new database. Partial and zero-byte files are not valid backups.
- Once PG17 accepts writes, the old PG16 directory cannot directly replace current data. Complete PostGIS/pg_ivm migration, BM25 maintenance, offline backup and `recover-pg16.sh` instructions remain in the document library.
- Authentication failures: check installation overrides and successful provisioning. Network failures: verify `vos_default`, aliases and internal ports. Redis authentication must match the current injected host password.
- Provisioning refreshes managed permissions/extensions without deleting business data. Application-owned databases such as V-Scheduler's are maintained by those applications; installing PGV does not create them automatically.
- Complete documents retain extension versions, ARM/BM1688/64 KiB hardware boundaries and historical test results. A successful build is not proof of acceptance on every device.

## Complete document library

Read the bundled user manual, image/release notes, PG16 → PG17 migration/recovery, VOS deployment and full installation configuration using the navigation. Original documents retain their source language and historical verification limits. Historical PG16 procedures do not apply unchanged to PG17. Source links do not execute commands or modify databases.
