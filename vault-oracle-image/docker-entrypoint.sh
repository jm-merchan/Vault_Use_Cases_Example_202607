#!/bin/sh
set -eu

if [ "${1:-}" = "server" ]; then
  shift
  set -- vault server "$@"
elif [ "${1:-}" = "version" ]; then
  set -- vault "$@"
fi

exec "$@"
