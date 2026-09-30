#!/bin/sh
set -eu
# opkg --offline-root is for package inspection, never live installation.
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
# The builder inserts router-platform.sh functions here (before this call).
tt_install_platform --from-ipk
