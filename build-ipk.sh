#!/bin/sh
# Build on a developer computer; Python is never required on the router.
set -eu
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SRC/tools/build-ipk.py" --write-online "$@"
