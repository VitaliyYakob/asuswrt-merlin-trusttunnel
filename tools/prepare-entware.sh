#!/bin/sh
# Dependency preparation runs OUTSIDE opkg maintainer scripts/its package lock.
set -eu
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
[ "$#" -eq 1 ] && [ "$1" = --lab-only ] || { echo 'Usage: prepare-entware.sh --lab-only' >&2; exit 2; }
SRC=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SRC/router-platform.sh"
tt_install_bootstrap_timeout
tt_install_platform ''
umask 077
WORK=$(mktemp -d /opt/ttm-setup-dependencies.XXXXXX)
chmod 700 "$WORK"
printf '%s\n' trusttunnel-merlin-staging-v1 >"$WORK/.trusttunnel-owned"
printf 'Dependency rollback record: %s\n' "$WORK"
opkg list-installed >"$WORK/packages.before"
opkg update
# Install only required packages, never an Entware-wide upgrade.
# jq-full conflicts with minimal jq: save BOTH IPKs before replacing it.
if opkg list-installed | awk '$1=="jq" {found=1} END {exit !found}'; then
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
fi
opkg install jq-full flock curl ca-bundle openssl-util gnupg coreutils-id coreutils-sha256sum \
    coreutils-mktemp coreutils-base64 coreutils-od coreutils-stat coreutils-timeout coreutils-mkfifo tar
jq -en '"merlin" | test("^merlin$")' >/dev/null
(exec 9>"$WORK/flock-test"; flock -w 1 9)
opkg list-installed >"$WORK/packages.after"
printf '%s\n' 'Dependencies ready; no VPN, Wi-Fi or firmware settings changed.'
