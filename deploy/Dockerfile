FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
# Keep in step with KUBO_V in relay/install-relay.sh — deploy.sh asserts they match and passes the
# installer's value, so a hosted node and a self-installed one never run different IPFS versions.
# They already had: this image sat on v0.29.0 while the installer pinned v0.43.0.
ARG KUBO_VERSION=v0.43.0
RUN curl -sL https://dist.ipfs.tech/kubo/${KUBO_VERSION}/kubo_${KUBO_VERSION}_linux-amd64.tar.gz | tar -xz -C /tmp \
    && mv /tmp/kubo/ipfs /usr/local/bin/ipfs && rm -rf /tmp/kubo
RUN pip install --no-cache-dir nanopy pynacl
WORKDIR /app
COPY app/ /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# A comma-separated list: rpc() tries them in order and fails over, so one datacenter-blocked or
# throttled public RPC can't make every balance read 0. (Lead with the highest published limit.)
# IPFS_PATH is set by entrypoint.sh (onto the persistent volume), so it's intentionally not fixed here.
ENV XC_NANO_RPC=https://nanoslo.0x.no/proxy,https://rpc.nano.to,https://rainstorm.city/api,https://node.somenano.com/proxy XC_FUND_NEW=0
EXPOSE 8790
CMD ["/entrypoint.sh"]
