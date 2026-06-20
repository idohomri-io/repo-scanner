FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git jq ca-certificates curl tar python3 \
    && rm -rf /var/lib/apt/lists/*

ARG OSV_SCANNER_VERSION=2.3.8
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) osv_arch=amd64 ;; \
        arm64) osv_arch=arm64 ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/osv-scanner_linux_${osv_arch}" \
        -o /usr/local/bin/osv-scanner; \
    chmod +x /usr/local/bin/osv-scanner; \
    osv-scanner --version

WORKDIR /app
COPY scan.sh entrypoint.sh /app/
COPY lib/ /app/lib/
COPY web/ /app/web/
COPY repos.txt /app/repos.txt
RUN chmod +x /app/scan.sh /app/entrypoint.sh && mkdir -p /app/reports /app/logs

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
