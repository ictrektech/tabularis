# PGV with Tabularis on VOS

This fork owns one VOS app, `com.ictrek.pgv`: the existing PGV PostgreSQL service,
a dedicated shared Redis, and Tabularis as the data viewer. Upstream desktop,
package-registry and release workflows have been removed. The only workflow is
our tag-triggered VOS pull-package release.

## Compatibility and storage

PostgreSQL aliases `pgv`, `ictrek-pgv`, `shared-pgv`, port 5432, host debug port
25432, application databases/roles, VOS-injected passwords, and PG16-to-PG17
migration are unchanged. `data` and `config` retain their existing locations.
The copied PGV sources and verification scripts are under `pgv/`. Legacy PG16
prebuilt LFS binaries are retained in the original PGV repository rather than
imported into this public fork; current PG17 builds do not consume them.

Redis uses only `pgv-redis` / `ictrek-pgv-redis`, port 6379 inside `vos_default`,
with no published host port. It requires `VOS_REDIS_PASSWORD`; AOF data remains
in the app's `redis` directory. Existing HybRAG instances retain their own Redis
until explicitly reconfigured and their queue/session data handled.

The viewer replaces pgweb at `/app/com.ictrek.pgv/`, with the existing 25433
host debug port. Open it through the VOS sidebar: the frontend uses OIDC
Fastpath and PKCE; the server verifies the access token with the platform's
injected internal userinfo endpoint. Because this workspace controls shared
superuser connections, only the verified VOS `admin` account may enter. No
platform token is stored in browser storage or logs. The internal Tabularis
backend listens on loopback only. Its proxy secret is generated per start and
never accepted from external headers. The native server uses its administrator mode so the verified VOS admin can
manage themes, settings and connections. That authority is confined to the
unprivileged viewer container: it mounts only its private viewer data, has no
Docker socket and no other host filesystem mounts. Native cookie sessions and CSRF checks
remain enabled; cookie paths are scoped to this app. App-shell frame policy
allows same-origin VOS embedding; plugin sandbox policies stay unchanged.

VOS login initializes the native restore list with both managed connections,
so they open automatically unless session restoration is disabled in settings.
Startup idempotently creates/updates `PGV PostgreSQL` and `PGV Redis` with the
injected credentials, retaining their saved IDs. Passwords use Tabularis's
encrypted file secret store. The built-in PostgreSQL driver is retained and its plugin migration nudge is disabled in the VOS build. Redis driver 0.4.1 is bundled at image-build time;
no plugin download is needed during installation or use. Connection settings,
secrets and the encryption key persist in `viewer` below the existing app's
private storage root. Back up this directory with `data`, `config` and `redis`.

## Build and publish images

Run Git only on the local checkout. Before each remote build/test, rsync this
repository to `~/dev/repos/tabularis` on a host matching the architecture.
Run the following there; build outputs go under `~/dev/build/tabularis`:

```sh
./build_image.sh --sheet AMD_with_cuda --images tabularis --build-only
./build_image.sh --sheet ARM_without_cuda --images tabularis --build-only
```

Omit `--build-only` to push the verified image and record it in Feishu. The
`tabularis` component gets its own column when absent; row 2 records the SWR
repository and dated rows record tags. The canonical spreadsheet is fixed in
`scripts/record_image.py`. Credentials are read from the existing host-side
Feishu configuration, never committed.

Unchanged `pgv` and Redis image names/tags are reused. To rebuild PostgreSQL as
well, select `--images pgv,tabularis`; the existing PGV build script and migration
gates run from `pgv/`. Its portable ARM vendor requirements still apply.

## One VOS package

The shared package templates live in `ictrek.app/`. Packaging resolves both
`pgv` and `tabularis` from the canonical Feishu sheet for each architecture and
includes the same published Redis base images as HybRAG. No database image
rebuild is needed for a viewer-only change.

After code delivery and successful image publication/table updates, run locally:

```sh
./ictrek.app/scripts/update_version.sh patch
```

This pushes only `vos-pgv-v<version>`. GitHub Actions creates the public release,
checks the pull package, and publishes it through the VOS App Store SSH tunnel.
The fork needs `FEISHU_APP_ID`, `FEISHU_APP_SECRET`, `APPSTORE_IP` and
`APPSTORE_TOKEN` in Actions secrets; the fixed spreadsheet ID is not a secret.

Keep the app ID, version sequence and storage root when upgrading an existing
PGV installation. Rolling back the viewer uses the previous PGV app package;
never replace a PG17 database with a stale PG16 backup after new writes.

## Verification

Run `node --test docker/vos/gateway.test.mjs` on the synchronized build host.
Frontend checks cover mounted HTTP/WebSocket URLs and browser navigation as
well as the existing transport and bootstrap tests. Container acceptance must
also verify native authentication rejection, idempotent managed connections,
PostgreSQL queries, Redis reads/writes, WebSocket upgrade and persisted secrets
after recreation. A build or a reachable health port alone is not VOS UI acceptance.

The VOS workspace does not fetch the optional plugin registry on startup. Bundled
PostgreSQL and Redis drivers remain available offline; Settings supports explicit refresh.

If App Store publication fails after the GitHub Release exists, dispatch the
existing `vos-release.yml` workflow with `version=<published version>`. It verifies
the released archive digest and retries only App Store publication; it does not
rebuild images, alter the release tag or replace the published archive.
