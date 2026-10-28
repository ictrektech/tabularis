# syntax=docker/dockerfile:1.7
ARG NODE_IMAGE=node:24.18.0-trixie-slim
ARG RUST_IMAGE=rust:1-trixie
ARG RUNTIME_IMAGE=debian:trixie-slim
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS web-ui
WORKDIR /src
RUN npm install -g pnpm@10.30.3
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store pnpm fetch --frozen-lockfile
COPY roadmap.json VOS.md ./
COPY pgv/README.md pgv/PG17-MIGRATION.md ./pgv/
COPY ictrek.app/src/README.zh-CN.md ictrek.app/src/README.en.md ictrek.app/src/configs.yml ./ictrek.app/src/
COPY packages ./packages
COPY plugins/manifest.schema.json ./plugins/manifest.schema.json
RUN --mount=type=cache,id=pnpm-store,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --offline \
    && TABULARIS_WEB_BASE_PATH=/app/com.ictrek.pgv/ pnpm build

FROM ${RUST_IMAGE} AS server
RUN sed -i 's|deb.debian.org|mirrors.huaweicloud.com|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Retries=3 update && apt-get install -y --no-install-recommends libdbus-1-dev pkg-config perl make && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ARG CRATES_MIRROR=sparse+https://rsproxy.cn/index/
RUN mkdir -p /usr/local/cargo && printf '[source.crates-io]\nreplace-with = "mirror"\n[source.mirror]\nregistry = "%s"\n' "$CRATES_MIRROR" > /usr/local/cargo/config.toml
ENV CARGO_HTTP_MULTIPLEXING=false CARGO_HTTP_TIMEOUT=120
COPY plugins/manifest.schema.json ./plugins/manifest.schema.json
COPY packages/web-ui/src/schemas ./packages/web-ui/src/schemas
COPY packages/web-ui/src/themes ./packages/web-ui/src/themes
COPY src-tauri ./src-tauri
RUN --mount=type=cache,id=tabularis-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=tabularis-cargo-target,target=/src/src-tauri/target \
    cd src-tauri && CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
    cargo build --release --locked --no-default-features --bin tabularis \
    && install -Dm755 target/release/tabularis /out/tabularis

FROM ${RUNTIME_IMAGE}
RUN sed -i 's|deb.debian.org|mirrors.huaweicloud.com|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Retries=3 update && apt-get install -y --no-install-recommends ca-certificates curl tini openssh-client libdbus-1-3 gosu libatomic1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --user-group --home-dir /data --no-create-home tabularis
COPY --from=web-ui /usr/local/bin/node /usr/local/bin/node
COPY --from=server /out/tabularis /usr/bin/tabularis
COPY --from=web-ui /src/packages/web-ui/dist /usr/lib/tabularis/web-ui
COPY vendor/redis /usr/lib/tabularis/redis
COPY docker/vos /usr/lib/tabularis/vos
COPY LICENSE /usr/share/doc/tabularis/LICENSE
ENV HOME=/data TABULARIS_DATA_DIR=/data TABULARIS_SECRET_STORE=file
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8081
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=6 CMD ["curl", "-fsS", "http://127.0.0.1:8081/healthz"]
ENTRYPOINT ["tini", "--", "/bin/sh", "/usr/lib/tabularis/vos/entrypoint.sh"]
