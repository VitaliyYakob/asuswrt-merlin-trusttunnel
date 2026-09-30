#!/bin/sh
set -eu
[ -z "${IPKG_INSTROOT:-}" ] || exit 0
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
case "${1:-}" in
    upgrade) tt_install_disabled;;
    remove)
        # Explicit package removal releases traffic and retains private settings/CLI.
        # A failed native removal prevents opkg from discarding its own payload.
        exec sh /opt/share/asuswrt-merlin-trusttunnel/uninstall.sh --keep-config --confirm-release-traffic
        ;;
    *) echo 'Unsupported opkg removal action' >&2; exit 2;;
esac
