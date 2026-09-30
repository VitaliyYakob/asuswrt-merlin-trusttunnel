#!/bin/sh
set -eu
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
# Dependencies were resolved by opkg. Do not reenter opkg while it holds its lock.
exec sh /opt/share/asuswrt-merlin-trusttunnel/tools/setup-router.sh --lab-only --from-ipk
