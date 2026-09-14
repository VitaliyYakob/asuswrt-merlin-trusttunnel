#!/bin/sh
set -eu
[ "${1:-}" = --confirm-release-traffic ] || { echo 'Usage: sh uninstall.sh --confirm-release-traffic' >&2; exit 2; }
/jffs/addons/trusttunnel/trusttunnel.sh uninstall-webui
rm -f /opt/etc/init.d/S99trusttunnel
# Keep credentials, code and binary for inspection/recovery; explain retained files.
printf '%s\n' 'Hooks, menu and owned network objects removed. Source/configuration and client binary retained.'
