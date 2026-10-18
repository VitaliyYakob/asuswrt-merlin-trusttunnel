#!/bin/sh
# Full disabled installation from an unpacked, trusted source release.
# No remote shell execution, latest release lookup, firmware upgrade or VPN start.
set -eu
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CLIENT_VERSION=1.1.5
ARCHIVE_SHA256=db17e4e2f9712de269b8e3196491324487fe9077c223e50b602668d888b5e81f
# Binary signature checked against upstream key 28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6.
CLIENT_SHA256=0eceaaf0c7afd07b10dd66262c7812ec52aa0ed631d65373f58f4b8318fb5869
verify_archive() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    [ "$(sha256sum "$1" | awk '{print $1}')" = "$ARCHIVE_SHA256" ] || {
        echo 'Official archive SHA-256 mismatch; nothing extracted or executed' >&2; return 1;
    }
}
# Offline verification entry point; performs no installation or network calls.
if [ "${1:-}" = --verify-archive ] && [ "$#" -eq 2 ]; then verify_archive "$2"; exit $?; fi
[ "${1:-}" = --lab-only ] && { [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --from-ipk ]; }; } || {
    echo 'Usage: sh tools/setup-router.sh --lab-only [--from-ipk] (experimental; installs disabled)' >&2; exit 2;
}
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SRC/tools/router-platform.sh"
FROM_IPK=${2:-}
[ "$FROM_IPK" = --from-ipk ] || tt_install_bootstrap_timeout
tt_install_platform "$FROM_IPK"
[ -f "$SRC/install.sh" ] && [ -f "$SRC/tools/install-client.sh" ] || exit 1
if [ "$FROM_IPK" != --from-ipk ]; then sh "$SRC/tools/prepare-entware.sh" --lab-only; fi
# In maintainer context, only validate dependencies; never acquire opkg's lock.
for utility in jq id sha256sum mktemp base64 od stat flock curl openssl gpg timeout tar; do
    type "$utility" >/dev/null 2>&1 || { echo "Missing utility: $utility" >&2; exit 1; }
done
jq -en '"merlin" | test("^merlin$")' >/dev/null
umask 077
WORK=$(mktemp -d /opt/ttm-setup-install.XXXXXX)
chmod 700 "$WORK"
printf '%s\n' trusttunnel-merlin-staging-v1 >"$WORK/.trusttunnel-owned"
printf 'Installation record: %s\n' "$WORK"
(exec 9>"$WORK/flock-test"; flock -w 1 9)
CLIENT_INSTALLED_AT=
# Reinstalling the addon MUST NOT downgrade an owned, previously verified CLI.
if tt_install_existing_client; then
    printf '%s\n' 'Preserving existing verified TrustTunnel CLI.'
else
    client_state=$?
    [ "$client_state" -eq 1 ] || { echo 'Existing client is unknown or corrupt; installation refused' >&2; exit 1; }
    ARCHIVE="trusttunnel_client-v${CLIENT_VERSION}-linux-aarch64"
    curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 180 \
        "https://github.com/TrustTunnel/TrustTunnelClient/releases/download/v${CLIENT_VERSION}/${ARCHIVE}.tar.gz" -o "$WORK/client.tar.gz"
    verify_archive "$WORK/client.tar.gz"
    # Verified immutable archive; extract only the two expected files via stdout.
    tar -xOzf "$WORK/client.tar.gz" "$ARCHIVE/trusttunnel_client" >"$WORK/client"
    tar -xOzf "$WORK/client.tar.gz" "$ARCHIVE/trusttunnel_client.sig" >"$WORK/client.sig"
    SIGNED_SHA=$(sh "$SRC/tools/verify-client.sh" "$WORK/client" "$WORK/client.sig" "$SRC/addon/share/client-release-key.asc")
    [ "$SIGNED_SHA" = "$CLIENT_SHA256" ] || { echo 'Unexpected signed client digest' >&2; exit 1; }
    sh "$SRC/tools/install-client.sh" "$WORK/client" "$CLIENT_SHA256"
    CLIENT_INSTALLED_AT=$(date +%s)
fi
sh "$SRC/install.sh" --lab-only
if [ -n "$CLIENT_INSTALLED_AT" ]; then
    # Record the real first installation too; do not invent a historical date
    # when merely preserving a client that was installed before this release.
    exec 9>/tmp/trusttunnel/control.lock
    flock -w 20 9
    tt_install_disabled
    metadata=/jffs/addons/trusttunnel/config/client-release.json
    tt_error() { printf 'TrustTunnel: %s\n' "$*" >&2; }
    . "$SRC/addon/lib/backup.sh"
    tt_backup_private "$metadata"
    jq -n --arg version "$CLIENT_VERSION" --arg sha "$CLIENT_SHA256" --argjson at "$CLIENT_INSTALLED_AT" \
        '{version:$version,tag:("v"+$version),channel:"stable",sha256:$sha,installed_at:$at}' >"$WORK/installed.json"
    [ "$(sha256sum /opt/trusttunnel/bin/trusttunnel_client | awk '{print $1}')" = "$CLIENT_SHA256" ] || exit 1
    stage=$(mktemp "$metadata.XXXXXX")
    cp "$WORK/installed.json" "$stage" && chmod 600 "$stage" && mv -f "$stage" "$metadata"
    exec 9>&-
fi
rm -f "$WORK/client.tar.gz" "$WORK/client" "$WORK/client.sig" "$WORK/flock-test"
rm -f "$WORK/installed.json"
printf '%s\n' 'Installation succeeded; downloaded client staging removed.' >"$WORK/result"
printf '%s\n' 'Setup complete. VPN is disabled. Configure the connection and test networks over HTTPS.'
