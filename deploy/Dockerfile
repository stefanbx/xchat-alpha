FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN curl -sL https://dist.ipfs.tech/kubo/v0.29.0/kubo_v0.29.0_linux-amd64.tar.gz | tar -xz -C /tmp \
    && mv /tmp/kubo/ipfs /usr/local/bin/ipfs && rm -rf /tmp/kubo
RUN pip install --no-cache-dir nanopy pynacl
WORKDIR /app
COPY app/ /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV XC_NANO_RPC=https://rpc.nano.to IPFS_PATH=/tmp/ipfsB XC_FUND_NEW=0
EXPOSE 8790
CMD ["/entrypoint.sh"]
