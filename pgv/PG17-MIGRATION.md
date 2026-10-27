# PGV PostgreSQL 16 → 17

PGV's PG17 candidate uses `paradedb/paradedb:v0.25.11-pg17` with
`pg_search 0.25.11`, `vector 0.8.4`, `pg_cron 1.6`, `vchord 0.4.3`, and
`vectors 0.3.0`. The `vectors` package installs into the same `vectors`
schema as the PG16 package. PostgreSQL 17 cannot open a PG16 data directory.
The VOS package detects and migrates existing PG16 data when the user updates
PGV; the user does not need SQL or terminal access.

## Automatic VOS upgrade

The one-shot `ictrek-pgv-migrate-*` service runs before PostgreSQL. It checks
the existing application storage path:

| Data state | Action |
| --- | --- |
| No cluster | Start PG17 as a new installation. |
| PG17 | Start the existing cluster. |
| PG16 | Dump every database locally, restore and provision an isolated PG17 cluster, then switch `data` to PG17. |
| Other major / unreadable cluster | Stop with a diagnostic; never initialize over existing data. |

PGV 0.0.33 uses PG16 (`*_16_20260717` images), so it follows the same PG16
path as later PG16 releases. Routing uses `PG_VERSION` and each database's
installed extensions, not a guessed app-version range. The migration image
includes separate PG16/PG17 PostGIS libraries and dependencies for geometry,
raster, topology and SFCGAL. This fixes the PG16 PostGIS omission in the
0.0.48 ARM migration image; PG17 libraries must never be used by PG16.
The historical ARM image also omitted PG16 `pg_ivm`; both majors now include
`pg_ivm 1.15` or later. IMMV query trees/OIDs are not copied across majors:
the source server exports SQL definitions and the PG17 restore uses
`pgivm.restore_immv` to register the existing restored tables, preserving their
data and dependent objects. Metadata counts are checked before cutover and
databases with IMMVs get session preloading even when VOS retains an older
shared-preload config. See the [upstream metadata restore procedure](https://github.com/sraoss/pg_ivm/blob/v1.15/README.md#pg_ivm_dump_metadata).

Before export, migration records extension versions and checks the PG16 C
libraries and PG17 extension control files. Missing support stops the migration
with the affected extension/library. Exports are written as `.partial`, checked
with `pg_restore -l`, then renamed to `.dump` only after successful export.
`backup-complete` marks a complete set of role/database exports. Partial files
and historical zero-byte dumps are not backups. A file lock rejects concurrent
migrations on the same storage.

The service retains the old cluster as `data-pg16-backup` and protected dumps
under `pgv-migration-backups`. If dump, restore, or provisioning fails, the
active `data` path remains PG16 and the new database service does not start.
A retry removes only an incomplete staging directory created by the migration
service, then repeats the work. An interrupted directory switch is recovered
before PGV starts. No database server used for migration is exposed on the
VOS network.
If the old PG16 server was terminated without a clean shutdown and left a
`postmaster.pid`, migration stops without touching the data. An administrator
must establish that the old server is stopped and recover it before retrying;
the app user is not asked to run database commands.

The role backup retains passwords for application-owned roles, including an
existing V-Scheduler database owner. The restored PGV administrator password
is set to the current VOS-injected `VOS_POSTGRES_PASSWORD`; PGV's own
provisioning then aligns the WeKnora, Immich and Nowen roles with their
configured environment variables. Existing V-Scheduler installations keep
their own `database.env` credential and do not need a new password.

After PG17 accepts new writes, a PG16 rollback needs those writes reconciled.
The retained PG16 directory and dumps are for administrator recovery, not an
installation step for the app user.

## Test gates

Run on every target CPU and page-size class before publishing a PGV app
package. The fixture and application smoke tests use temporary Docker data:

```bash
./scripts/verify_arm_runtime.sh --image <pgv-pg17-image>
./scripts/verify_pg17_migration.sh --image <pgv-pg17-image> --old-image <pgv-pg16-image>
./scripts/verify_pg17_auto_migration.sh --image <pgv-pg17-image> --old-image <pgv-pg16-image> --scheduler-image <matching-v-scheduler-image>
./scripts/verify_pg17_postgis_migration.sh --image <pgv-pg17-image> --old-image <pgv-0.0.33-image>
./scripts/verify_pg17_live_clone.sh --source-container <installed-pg16-container> --image <pgv-pg17-image>
./scripts/verify_pg17_v_scheduler.sh --image <pgv-pg17-image> --scheduler-image <matching-v-scheduler-image>
```

The fixture test covers WeKnora BM25/HNSW, Immich VectorChord and legacy
`vectors` data, Nowen data, PGV provisioning, and starting the untouched PG16
volume again. The automatic test covers a fresh installation, a failed
provisioning check followed by a successful retry, an idempotent PG17 start,
and recovery from an interrupted directory switch.
With `--scheduler-image`, it also verifies the existing V-Scheduler role's
original password, starts the unchanged controller image against migrated
data, submits a task, and checks its persistence. The PGV administrator is
tested with the current VOS password after migration.
The live-clone test performs a read-only dump of every database in the
installed container and restores it into an isolated PG17 volume.
The PostGIS gate checks the entire historical PG16 library/extension inventory,
then uses the actual 0.0.33 image with geometry/geography, GiST,
raster and topology data, all four PostGIS extensions, and a maintained pg_ivm
view with a dependent SQL view. It tests incremental updates after migration.
It exercises the
administrator script, checks its independent offline backup, verifies data,
and confirms that recovery rejects storage mounted by a running container.
`build_image.sh` runs this gate on both architectures; `PGV_POSTGIS_SOURCE_IMAGE`
can select another verified PG16 source image.
The V-Scheduler test runs its existing controller image against a disposable
PG17 `v_scheduler` database, checks SQL migrations and health, submits a task,
and verifies the task is persisted. V-Scheduler uses ordinary PostgreSQL
features; it does not need PGV's vector or search extensions.

The ARM candidate uses a rebuilt PG17 `vectors 0.3.0` library without its
process-wide jemalloc allocator. `scripts/build_vectors_pg17_arm.sh` pins the
upstream source commit and patched pgrx commit used for the PG17 release,
replaces only `vectors.so` in the official package, and checks the unchanged
extension SQL hash. The 2026-10-14 candidate passed extension and migration tests on two
4 KiB ARM hosts; that base also passed a Cortex-A53 QEMU smoke test
covering all five extensions, a `vectors` distance query and BM25. The 64 KiB
and BM1688 hosts still require physical runtime
verification before an ARM PGV release. Emulation cannot establish the host
kernel page-size behavior. `build_image.sh` permits ARM candidate builds with
`--build-only` while that gate remains open. An explicitly authorized release
can use `PGV_RELEASE_WITHOUT_PHYSICAL_ARM=1`; this does not clear the pending
physical validation.

The 2026-10-15 legacy-runtime fix passed the actual 0.0.33 image's PostGIS,
pg_ivm and offline-backup regression gates on native AMD64 and emulated ARM64.
The original PG16 directory remained available after cutover. Native ARM test
hosts were offline during this fix; these results do not replace physical ARM
or 64 KiB validation.

## Administrator recovery after a failed installation

App users should update/install the fixed PGV package through VOS. If a failed
task has removed the app record, an administrator can confirm that all PGV
containers using the storage have stopped, then run:

```bash
./scripts/migrate_pg16_storage.sh \
  --image <fixed-pgv-image-for-this-architecture> \
  --storage <original-VOS-app-storage-directory> \
  --env-file <protected-docker-environment-file> \
  --backup-root <independent-backup-directory>
```

The published VOS package also includes the same script as `recover-pg16.sh`
beside `init/`. Extract `app.tar.gz` and run `bash ./recover-pg16.sh` with the
same arguments; a source checkout is not required on the affected machine.

`--storage` is the application storage root containing `data/PG_VERSION`, not
the inner PostgreSQL directory. The environment file uses Docker `KEY=value`
syntax. Supply the existing `VOS_POSTGRES_PASSWORD` (or `POSTGRES_PASSWORD`),
`POSTGRES_SUPERUSER`/`POSTGRES_USER`, and application database configuration.
Omitted app values use the VOS package defaults. Keep this file private; never
put passwords on the command line. `--init-dir` can select a fixed package's
`init` directory when the script is distributed separately from the repository.

The script refuses running containers mounting the storage. Under the same
migration lock it creates a full offline PG16 tar archive with a SHA-256
checksum before starting PG16, then invokes the installer's migration script.
The backup destination must be outside application storage and have room for
the full cluster. Application storage also needs room for logical exports and
the PG17 cluster. Failure leaves PG16 active. After success, install the matching
fixed VOS package: it detects PG17 and skips migration. Verify application health,
database contents and access before removing any backup. This recovery command
does not start the VOS database service or change its application record.

## AI Album

AI Album's packaged configuration continues to use its own PostgreSQL image
by default. No AI Album source change is required for a test connection to PGV:
use `DB_HOSTNAME=pgv`, `DB_USERNAME=immich`, `DB_DATABASE_NAME=immich`, the
matching `DB_PASSWORD`, and `DB_VECTOR_EXTENSION=vectorchord` for its server
container on `vos_default`. PGV provisions the `immich` role and database with
`vector`, `vchord`, and `vectors` available.

To move an existing AI Album installation, pause it, back up its PostgreSQL 14
database and `/data` library, restore the database into a *new* PG17 PGV
database after creating `vector`, then restart the same AI Album server image
with the PGV connection settings. Keep its old database and library backup
until assets, search, and health are verified. A fresh AI Album 2.8.2 start
and a PG14 database restore followed by a PG17 PGV start passed on an isolated
ARM test network; no AI Album code was changed.
