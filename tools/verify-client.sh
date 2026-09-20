#!/bin/sh
# Offline signature verification; use a separately obtained upstream public key.
# No keyserver, no downloaded code execution, no personal GPG keyring changes.
set -eu
[ "$#" -eq 3 ] || { echo 'Usage: verify-client.sh BINARY SIGNATURE PUBLIC_KEY' >&2; exit 2; }
for input in "$@"; do [ -f "$input" ] && [ ! -L "$input" ] || exit 1; done
command -v gpg >/dev/null 2>&1 || { echo 'GnuPG is required on the verification computer' >&2; exit 1; }
umask 077
work=$(mktemp -d)
trap 'rm -f "$work/status" "$work/verified-binary"; rm -rf "$work/keyring"; rmdir "$work"' EXIT HUP INT TERM
mkdir "$work/keyring"
cp "$1" "$work/verified-binary"
gpg --batch --no-options --homedir "$work/keyring" --import "$3" >/dev/null 2>&1 || { echo 'Public key import failed' >&2; exit 1; }
gpg --batch --no-options --homedir "$work/keyring" --status-fd 1 --verify "$2" "$work/verified-binary" >"$work/status" 2>/dev/null || { echo 'Signature verification failed' >&2; exit 1; }
# Pinned primary fingerprint from TrustTunnelClient v1.1.5/VERIFY_RELEASES.md.
awk '$1=="[GNUPG:]" && $2=="VALIDSIG" && ($3=="28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6" || $NF=="28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6") {ok=1} END {exit !ok}' "$work/status" || { echo 'Unexpected signing key' >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$work/verified-binary" | awk '{print $1}'
else shasum -a 256 "$work/verified-binary" | awk '{print $1}'; fi
