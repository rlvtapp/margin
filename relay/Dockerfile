# Build stage: compiles the relay (SQLite is bundled, so only a C compiler is needed).
FROM rust:1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

# Run stage: a small image with just the binary.
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /data relay \
    && mkdir -p /data && chown relay /data
COPY --from=build /src/target/release/margin-relay /usr/local/bin/margin-relay
USER relay
ENV PORT=8080 DATABASE_PATH=/data/relay.sqlite3
EXPOSE 8080
VOLUME ["/data"]
CMD ["margin-relay"]
