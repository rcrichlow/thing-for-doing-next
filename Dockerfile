FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.16.0
ARG TARGETARCH

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl libpq-dev xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in amd64) zig_arch=x86_64 ;; arm64) zig_arch=aarch64 ;; *) exit 1 ;; esac \
    && curl --fail --location "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -C /opt -xf /tmp/zig.tar.xz \
    && ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /app
COPY build.zig ./
COPY src ./src
RUN zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --no-install-recommends -y curl libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 app
USER app
WORKDIR /app
COPY --from=builder /app/zig-out/bin/thing-for-doing-next /usr/local/bin/thing-for-doing-next

ENV PORT=3000
EXPOSE 3000
CMD ["thing-for-doing-next"]
