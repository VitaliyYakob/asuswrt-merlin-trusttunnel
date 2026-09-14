#!/bin/sh
# Installs source files only. Never downloads or automatically starts a client.
set -eu
[ "${1:-}" = --lab-only ] && [ "$#" -eq 1 ] || { echo 'Usage: sh install.sh --lab-only (ISOLATED LAB ONLY)' >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo 'root required' >&2; exit 1; }
command -v nvram >/dev/null && nvram get rc_support | grep -qw am_addons || { echo 'Merlin Addons API required' >&2; exit 1; }
for tool in jq flock ip sha256sum cru; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
[ -d /opt/etc/init.d ] || { echo 'Entware /opt is not ready' >&2; exit 1; }
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DST=/jffs/addons/trusttunnel
[ ! -f "$DST/config/enabled" ] || { echo 'Disable the existing addon before upgrade' >&2; exit 1; }
[ ! -L "$DST" ] || { echo 'Refusing symlinked installation directory' >&2; exit 1; }
umask 077
mkdir -p "$DST/config" /opt/trusttunnel/bin
# Preserve private configuration across reinstall. No rm -rf on shared paths.
cp -R "$SRC/addon/lib" "$SRC/addon/share" "$SRC/addon/web" "$DST/"
cp "$SRC/addon/trusttunnel.sh" "$SRC/addon/trusttunnel_page.asp" "$DST/"
chmod 755 "$DST/trusttunnel.sh"
printf '%s\n' 'Laboratory alpha; not a verified leak-prevention product.' >"$DST/config/LAB_ONLY_ACKNOWLEDGED"
chmod 700 "$DST/config"
cp "$SRC/addon/S99trusttunnel" /opt/etc/init.d/S99trusttunnel
chmod 755 /opt/etc/init.d/S99trusttunnel
"$DST/trusttunnel.sh" install-webui
printf '%s\n' 'Installed, not enabled. Open VPN > TrustTunnel. Import credentials by SSH before starting.'
