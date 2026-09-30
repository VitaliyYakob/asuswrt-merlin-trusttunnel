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
[ "${1:-}" = --lab-only ] && [ "$#" -eq 1 ] || {
    echo 'Usage: sh tools/setup-router.sh --lab-only (experimental; installs disabled)' >&2; exit 2;
}
[ -z "${TT_ROOT:-}" ] || { echo 'Installation is prohibited with TT_ROOT' >&2; exit 1; }
[ "$(uname -s):$(uname -m)" = Linux:aarch64 ] || { echo 'Linux aarch64 router required' >&2; exit 1; }
# Firmware BusyBox may omit both id and command builtins; no dependencies yet.
[ "$(awk '/^Uid:/ {print $3}' /proc/self/status)" = 0 ] || { echo 'root required' >&2; exit 1; }
type nvram >/dev/null 2>&1 && nvram get rc_support | grep -qw am_addons || { echo 'Merlin Addons API required' >&2; exit 1; }
[ "$(nvram get jffs2_scripts)" = 1 ] || { echo 'Enable JFFS custom scripts in Merlin first' >&2; exit 1; }
type opkg >/dev/null 2>&1 && [ -d /opt/etc/init.d ] || { echo 'Working Entware is required' >&2; exit 1; }
CONFIG=/jffs/addons/trusttunnel/config
[ ! -e "$CONFIG/enabled" ] && [ ! -e "$CONFIG/transaction" ] && [ ! -e "$CONFIG/client-update-journal.json" ] || {
    echo 'Disable the addon and finish pending recovery before installation' >&2; exit 1;
}
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$SRC/install.sh" ] && [ -f "$SRC/tools/install-client.sh" ] || exit 1
umask 077
WORK="/opt/ttm-setup-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -m 700 "$WORK"
printf '%s\n' trusttunnel-merlin-staging-v1 >"$WORK/.trusttunnel-owned"
printf 'Installation record: %s\n' "$WORK"
opkg list-installed >"$WORK/packages.before"
# Install only missing utilities. Do not run an Entware-wide upgrade.
for dependency in jq:jq-full id:coreutils-id sha256sum:coreutils-sha256sum mktemp:coreutils-mktemp base64:coreutils-base64 od:coreutils-od stat:coreutils-stat flock:flock curl:curl openssl:openssl-util gpg:gnupg timeout:coreutils-timeout tar:tar; do
    utility=${dependency%%:*}; package=${dependency#*:}
    if ! type "$utility" >/dev/null 2>&1; then opkg install "$package"; fi
    type "$utility" >/dev/null 2>&1 || { echo "Missing utility after installation: $utility" >&2; exit 1; }
done
# Entware's minimal jq exists but cannot validate our schemas or discover SSIDs.
if ! jq -en '"merlin" | test("^merlin$")' >/dev/null 2>&1; then
    if opkg list-installed | awk '$1=="jq" {found=1} END {exit !found}'; then
        # Packages conflict on the same paths. Download BOTH before removal;
        # normal remove refuses dependent packages, never force their removal.
        (cd "$WORK" && opkg download jq && opkg download jq-full)
        set -- "$WORK"/jq_*.ipk
        [ "$#" -eq 1 ] && [ -f "$1" ] || exit 1
        OLD_JQ=$1
        set -- "$WORK"/jq-full_*.ipk
        [ "$#" -eq 1 ] && [ -f "$1" ] || exit 1
        FULL_JQ=$1
        opkg remove jq
        if ! opkg install "$FULL_JQ"; then
            opkg install "$OLD_JQ" || echo "Restore jq manually from $OLD_JQ" >&2
            exit 1
        fi
    else
        opkg install jq-full
    fi
    jq -en '"merlin" | test("^merlin$")' >/dev/null 2>&1 || {
        echo 'jq with regex support is required (Entware jq-full)' >&2; exit 1;
    }
fi
# Firmware flock can lack the FD/timeout interface used by the controller.
if ! (exec 9>"$WORK/flock-test"; flock -w 1 9); then
    opkg install flock
    (exec 9>"$WORK/flock-test"; flock -w 1 9) || exit 1
fi
opkg list-installed >"$WORK/packages.after"
ARCHIVE="trusttunnel_client-v${CLIENT_VERSION}-linux-aarch64"
curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 180 \
    "https://github.com/TrustTunnel/TrustTunnelClient/releases/download/v${CLIENT_VERSION}/${ARCHIVE}.tar.gz" -o "$WORK/client.tar.gz"
verify_archive "$WORK/client.tar.gz"
tar -xzf "$WORK/client.tar.gz" -C "$WORK"
# Both stages preserve previous owned files; neither starts the client.
sh "$SRC/tools/install-client.sh" "$WORK/$ARCHIVE/trusttunnel_client" "$CLIENT_SHA256"
sh "$SRC/install.sh" --lab-only
printf '%s\n' 'Setup complete. VPN is disabled. Configure the connection and test networks over HTTPS.'
