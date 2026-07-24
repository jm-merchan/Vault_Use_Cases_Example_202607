FROM docker.io/hashicorp/vault-enterprise:2.0.3-ent AS vault
FROM docker.io/josemerchan/vault-oracle-init:0.14.1-ent-ic23.26.3 AS oracle

FROM docker.io/oraclelinux:8-slim

RUN microdnf install -y ca-certificates libaio libcap libnsl shadow-utils \
    && microdnf clean all \
    && groupadd --gid 1000 vault \
    && useradd --uid 100 --gid 1000 --home-dir /home/vault --create-home --shell /sbin/nologin vault \
    && mkdir -p /vault/config /vault/data /vault/file /vault/logs /vault/plugins /opt/oracle \
    && chown -R 100:1000 /home/vault /vault /opt/oracle

COPY --from=vault /bin/vault /usr/local/bin/vault
COPY --from=oracle --chown=100:1000 /payload/vault/plugins /vault/plugins
COPY --from=oracle --chown=100:1000 /payload/opt/oracle /opt/oracle
COPY --chown=0:0 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/vault /usr/local/bin/docker-entrypoint.sh \
    && chmod -R a+rX /vault/plugins /opt/oracle

ENV NAME=vault \
    LD_LIBRARY_PATH=/opt/oracle/instantclient_23_26 \
    ORACLE_HOME=/opt/oracle/instantclient_23_26

USER 100:1000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["server", "-dev"]
