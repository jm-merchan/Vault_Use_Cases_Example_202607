FROM docker.io/josemerchan/vault-oracle-init:0.14.1-ent-ic19.26 AS oracle19
FROM docker.io/josemerchan/vault-oracle-init:vault2.0.3-ent-oracle0.14.1-ic23.26.3@sha256:a808e7b99335f24b8e49855a46da7482f4054d791fb5d254787b35a405e59b55

LABEL org.opencontainers.image.title="Vault Enterprise with Oracle Instant Client 19 and 23" \
      org.opencontainers.image.description="Oracle plugin runtime for Oracle Database 19c and Oracle Database Free/23ai"

USER 0:0

COPY --from=oracle19 --chown=100:1000 \
  /payload/opt/oracle/instantclient_19_26 \
  /opt/oracle/instantclient_19_26

COPY --chown=100:1000 oracle-plugin-ic19.sh /vault/plugins/oracle-plugin-ic19
COPY --chown=100:1000 oracle-plugin-ic23.sh /vault/plugins/oracle-plugin-ic23

RUN chmod 0755 \
      /vault/plugins/oracle-plugin-ic19 \
      /vault/plugins/oracle-plugin-ic23 \
    && test -x /vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64/vault-plugin-database-oracle \
    && test -f /opt/oracle/instantclient_19_26/libclntsh.so.19.1 \
    && test -f /opt/oracle/instantclient_23_26/libclntsh.so.23.1

# IC23 remains the safe default; each registered wrapper overrides it per process.
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient_23_26 \
    ORACLE_HOME=/opt/oracle/instantclient_23_26

USER 100:1000
