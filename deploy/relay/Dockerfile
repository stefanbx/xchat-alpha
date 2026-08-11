FROM python:3.12-slim
RUN pip install --no-cache-dir nanopy
WORKDIR /app
COPY app/ /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# Cache cap sized for the 256 MB machine (leaves room for Python + heads + state); pay-to-pin protects
# CIDs from eviction. XC_NANO_RPC lets the relay verify pin payments on-chain.
ENV XC_NANO_RPC=https://nanoslo.0x.no/proxy,https://rpc.nano.to,https://rainstorm.city/api XC_BLOB_CAP_MB=64
EXPOSE 7401
CMD ["/entrypoint.sh"]
