FROM python:3.12-slim
RUN pip install --no-cache-dir nanopy
WORKDIR /app
COPY app/ /app/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV XC_NANO_RPC=https://nanoslo.0x.no/proxy,https://rpc.nano.to,https://rainstorm.city/api
EXPOSE 7401
CMD ["/entrypoint.sh"]
