#!/bin/sh
# Install a local, independently verified binary. No network download; no 'latest'.
set -eu
[ "$#" -eq 2 ] || { echo 'Usage: sh tools/install-client.sh LOCAL_BINARY EXPECTED_SHA256' >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo 'root required' >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo 'This alpha installer targets aarch64 only' >&2; exit 1; }
[ ! -f /jffs/addons/trusttunnel/config/enabled ] || { echo 'Explicitly disable the addon before replacing its binary' >&2; exit 1; }
[ -f "$1" ] && [ ! -L "$1" ] || { echo 'A regular binary file is required' >&2; exit 1; }
printf '%s' "$2" | grep -Eq '^[0-9a-fA-F]{64}$' || { echo 'Invalid SHA-256 format' >&2; exit 1; }
actual=$(sha256sum "$1" | awk '{print $1}')
expected=$(printf '%s' "$2" | tr A-F a-f)
[ "$actual" = "$expected" ] || { echo 'SHA-256 mismatch' >&2; exit 1; }
# ELF magic, 64-bit, little-endian; e_machine EM_AARCH64 = 183.
magic=$(od -An -tx1 -N6 "$1" | tr -d ' \n')
machine=$(od -An -tu1 -j18 -N2 "$1" | awk '{print $1 ":" $2}')
[ "$magic" = 7f454c460201 ] && [ "$machine" = 183:0 ] || { echo 'Expected little-endian ELF64 aarch64 binary' >&2; exit 1; }
umask 077
mkdir -p /opt/trusttunnel/bin
stage=$(mktemp /opt/trusttunnel/bin/.client.XXXXXX)
trap 'rm -f "$stage"' EXIT HUP INT TERM
cp "$1" "$stage"
chmod 755 "$stage"
mv -f "$stage" /opt/trusttunnel/bin/trusttunnel_client
printf '%s\n' "$actual" >/opt/trusttunnel/bin/trusttunnel_client.sha256
printf '%s\n' 'Binary installed; kernel/ABI compatibility remains untested. Client not started.'
