FROM docker.io/oraclelinux:9-slim AS builder

ARG PLUGIN_VERSION=0.14.1+ent
ARG PLUGIN_SHA256=e14fc3474c6074b458d967098d448f357577fe77cc3c4b64401a4216b46ba372
ARG INSTANT_CLIENT_VERSION=23.26.3.0.0
ARG INSTANT_CLIENT_SHA256=fce485361332927f8328ea4b68d98968c6b0ea124e62470de8c9d0cef880130e

RUN microdnf install -y ca-certificates curl libaio unzip \
    && microdnf clean all

RUN set -eux; \
    plugin_archive="vault-plugin-database-oracle_${PLUGIN_VERSION}_linux_amd64.zip"; \
    plugin_url="https://releases.hashicorp.com/vault-plugin-database-oracle/${PLUGIN_VERSION}/${plugin_archive}"; \
    instant_client_archive="instantclient-basic-linux.x64-${INSTANT_CLIENT_VERSION}.zip"; \
    instant_client_url="https://download.oracle.com/otn_software/linux/instantclient/2326300/${instant_client_archive}"; \
    curl --fail --location --silent --show-error "${plugin_url}" --output "/tmp/${plugin_archive}"; \
    echo "${PLUGIN_SHA256}  /tmp/${plugin_archive}" | sha256sum --check --status; \
    curl --fail --location --silent --show-error "${instant_client_url}" --output "/tmp/${instant_client_archive}"; \
    echo "${INSTANT_CLIENT_SHA256}  /tmp/${instant_client_archive}" | sha256sum --check --status; \
    mkdir -p "/payload/vault/plugins/${plugin_archive%.zip}" /payload/opt/oracle; \
    unzip -q "/tmp/${plugin_archive}" -d "/payload/vault/plugins/${plugin_archive%.zip}"; \
    unzip -q "/tmp/${instant_client_archive}" -d /payload/opt/oracle; \
    cp -L /usr/lib64/libaio.so.1 /payload/opt/oracle/instantclient_23_26/libaio.so.1; \
    chmod -R a+rX /payload

FROM docker.io/library/busybox:1.37.0

COPY --from=builder --chown=1000:1000 /payload /payload

USER 1000:1000

ENTRYPOINT ["/bin/sh", "-ec"]
CMD ["cp -a /payload/vault/plugins/. /vault/plugins/ && cp -a /payload/opt/oracle/. /opt/oracle/"]
