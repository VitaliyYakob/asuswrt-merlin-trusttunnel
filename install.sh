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
tt_error() { printf 'TrustTunnel: %s\n' "$*" >&2; }
. "$SRC/addon/lib/backup.sh"
tt_backup_install "$DST" /opt/etc/init.d/S99trusttunnel
[ -z "$TT_INSTALL_BACKUP" ] || printf 'Previous addon files saved in %s\n' "$TT_INSTALL_BACKUP"
# Preserve private configuration across reinstall. No rm -rf on shared paths.
cp -R "$SRC/addon/lib" "$SRC/addon/share" "$SRC/addon/web" "$DST/"
cp "$SRC/addon/trusttunnel.sh" "$SRC/addon/trusttunnel_page.asp" "$DST/"
cp "$SRC/uninstall.sh" "$DST/uninstall.sh"
printf '%s\n' trusttunnel-merlin-addon-v1 >"$DST/.trusttunnel-owned"
chmod 755 "$DST/trusttunnel.sh"
printf '%s\n' 'Laboratory alpha; not a verified leak-prevention product.' >"$DST/config/LAB_ONLY_ACKNOWLEDGED"
chmod 700 "$DST/config"
cp "$SRC/addon/S99trusttunnel" /opt/etc/init.d/S99trusttunnel
chmod 755 /opt/etc/init.d/S99trusttunnel
# install-webui acquires the same lock. Release only after the complete code copy.
exec 9>&-
"$DST/trusttunnel.sh" install-webui
printf '%s\n' 'Installed, not enabled. Open VPN > TrustTunnel over HTTPS; SSH import is also available.'
