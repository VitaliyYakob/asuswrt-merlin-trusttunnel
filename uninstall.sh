#!/bin/sh
# No arguments: inspection only. Keep the downloaded release for a second run.
set -eu
ROOT=${TT_ROOT:-}
CTL="$ROOT/jffs/addons/trusttunnel/trusttunnel.sh"
MODE=${1:---dry-run}
case "$MODE" in
    --dry-run) [ "$#" -le 1 ] || exit 2;;
    --keep-config) [ "$#" -eq 2 ] && [ "$2" = --confirm-release-traffic ] || exit 2;;
    --purge) [ "$#" -eq 3 ] && [ "$2" = --confirm-release-traffic ] && [ "$3" = --confirm-delete-data ] || exit 2;;
    --confirm-release-traffic) [ "$#" -eq 1 ] || exit 2; MODE=--keep-config;;
    *) echo 'Usage: sh uninstall.sh [--dry-run | --keep-config --confirm-release-traffic | --purge --confirm-release-traffic --confirm-delete-data]' >&2; exit 2;;
esac
if [ "$MODE" != --dry-run ] && [ -n "$ROOT" ]; then
    echo 'Live uninstall is prohibited with TT_ROOT' >&2; exit 1
fi
if [ ! -f "$CTL" ]; then
    echo 'Controller not installed. No files or network objects were removed.'
    echo 'Check leftover /opt/trusttunnel and unmarked setup directories manually; no ownership is assumed.'
    exit 0
fi
[ ! -L "$CTL" ] || { echo 'Symlinked controller refused' >&2; exit 1; }
case "$MODE" in
    --dry-run) exec sh "$CTL" uninstall-plan;;
    --keep-config) exec sh "$CTL" uninstall keep --confirm-release-traffic;;
    --purge) exec sh "$CTL" uninstall purge --confirm-release-traffic --confirm-delete-data;;
esac
