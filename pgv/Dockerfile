ARG BASE_IMAGE=swr.cn-southwest-2.myhuaweicloud.com/ictrek/paradedb:amd64_0.25.11-pg17
ARG LEGACY_IMAGE=swr.cn-southwest-2.myhuaweicloud.com/ictrek/pgv:amd_16_20261012
FROM ${LEGACY_IMAGE} AS legacy_pg16
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG VCHORD_DEB=vendor/${TARGETARCH}/vchord-pg17.deb
ARG VECTORS_DEB=vendor/${TARGETARCH}/vectors-pg17.deb

# The one-shot VOS upgrade service starts the stopped PG16 cluster locally to
# dump it before PG17 can mount the same data path. Both bases use Debian 13.
COPY --from=legacy_pg16 /usr/lib/postgresql/16 /usr/lib/postgresql/16
COPY --from=legacy_pg16 /usr/share/postgresql/16 /usr/share/postgresql/16

# Older PGV packages (including 0.0.33) can contain PostGIS and pg_ivm databases.
# The ARM legacy image omits these, so copying its PG16 directory alone cannot
# provide a complete dump runtime. Install each major's own libraries
# and dependencies; a PG17 PostGIS library cannot be loaded by PG16.
RUN set -eux; \
    printf '\ncreate_main_cluster = false\n' >> /etc/postgresql-common/createcluster.conf; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      postgresql-16-postgis-3 postgresql-16-postgis-3-scripts \
      postgresql-17-postgis-3 postgresql-17-postgis-3-scripts \
      postgresql-16-pg-ivm postgresql-17-pg-ivm; \
    rm -rf /var/lib/apt/lists/*; \
    for major in 16 17; do \
      test -s /usr/share/postgresql/$major/extension/postgis.control; \
      test -s /usr/share/postgresql/$major/extension/pg_ivm.control; \
      for library in /usr/lib/postgresql/$major/lib/postgis*.so /usr/lib/postgresql/$major/lib/pg_ivm.so; do \
        test -s "$library"; \
        if ldd "$library" | grep 'not found'; then exit 1; fi; \
      done; \
    done

# ParadeDB includes pg_search, pgvector and pg_cron. Immich also needs
# VectorChord and legacy vectors 0.3 for pre-VectorChord database restores.
COPY ${VCHORD_DEB} /tmp/pgv/vchord.deb
COPY ${VECTORS_DEB} /tmp/pgv/vectors.deb
RUN set -eux; \
    dpkg -i /tmp/pgv/vchord.deb /tmp/pgv/vectors.deb; \
    rm -rf /tmp/pgv
