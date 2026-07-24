#!/bin/sh
set -eu

export LD_LIBRARY_PATH=/opt/oracle/instantclient_19_26
export ORACLE_HOME=/opt/oracle/instantclient_19_26

exec /vault/plugins/vault-plugin-database-oracle_0.14.1+ent_linux_amd64/vault-plugin-database-oracle "$@"

