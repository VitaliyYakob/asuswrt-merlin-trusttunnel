#!/bin/sh
# Installs source files only. Never downloads or automatically starts a client.
set -eu
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
[ "${1:-}" = --lab-only ] && [ "$#" -eq 1 ] || { echo 'Usage: sh install.sh --lab-only (experimental; installs disabled)' >&2; exit 2; }
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SRC/tools/router-platform.sh"
tt_install_platform --from-ipk
for tool in jq flock ip sha256sum cru mktemp base64 od stat openssl; do type "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
jq -en '"merlin" | test("^merlin$")' >/dev/null 2>&1 || {
    echo 'jq with regex support is required (Entware jq-full)' >&2; exit 1;
}
[ -d /opt/etc/init.d ] || { echo 'Entware /opt is not ready' >&2; exit 1; }
DST=/jffs/addons/trusttunnel
[ ! -f "$DST/config/enabled" ] || { echo 'Disable the existing addon before upgrade' >&2; exit 1; }
[ ! -e "$DST/config/transaction" ] || { echo 'Recover the pending transaction before upgrade' >&2; exit 1; }
[ ! -e "$DST/config/client-update-journal.json" ] || { echo 'Recover the interrupted client update before upgrade' >&2; exit 1; }
[ ! -L "$DST" ] || { echo 'Refusing symlinked installation directory' >&2; exit 1; }
[ ! -L "$DST/config" ] || { echo 'Refusing symlinked configuration directory' >&2; exit 1; }
umask 077
mkdir -p "$DST/config" /opt/trusttunnel/bin
[ ! -L /tmp/trusttunnel ] && [ ! -L /tmp/trusttunnel/control.lock ] || { echo 'Symlinked controller lock refused' >&2; exit 1; }
mkdir -p /tmp/trusttunnel
exec 9>/tmp/trusttunnel/control.lock
flock -w 20 9 || { echo 'Controller is busy' >&2; exit 1; }
tt_install_disabled
if [ -e "$DST/trusttunnel.sh" ]; then
    [ -f "$DST/.trusttunnel-owned" ] && [ ! -L "$DST/.trusttunnel-owned" ] &&
        [ "$(cat "$DST/.trusttunnel-owned")" = trusttunnel-merlin-addon-v1 ] || {
            echo 'Existing unmarked installation refused' >&2; exit 1;
        }
fi
# UI functions run in this shell under the existing control lock. No child
# controller reacquires the same lock and no service is started during setup.
tt_install_load() {
    TT_BASE=$DST
    for library in common config network service webui transaction transfer diagnostics client-update traffic-check; do
        # shellcheck disable=SC1090
        . "$TT_BASE/lib/$library.sh"
    done
}
tt_install_ui() {
    tt_install_load
    tt_hooks install && tt_mount_ui &&
        cru a TrustTunnelMerlin '* * * * * /jffs/addons/trusttunnel/trusttunnel.sh refresh >/dev/null 2>&1'
}
tt_install_ui_cleanup() {
    tt_install_load
    tt_hooks remove && tt_unmount_ui && cru d TrustTunnelMerlin
}
. "$SRC/addon/lib/install-transaction.sh"
tt_install_transaction "$SRC" "$DST" /opt/etc/init.d/S99trusttunnel
printf '%s\n' 'Installed, not enabled. Open VPN > TrustTunnel over HTTPS; SSH import is also available.'
