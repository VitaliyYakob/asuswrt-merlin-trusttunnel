#!/bin/sh
# Optional read-only hardware check. No cookies, credentials or control POSTs.
set -eu
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: check-webui-access.sh https://router:8443 [userN.asp]' >&2; exit 2; }
base=${1%/}; page=${2:-user1.asp}
printf '%s' "$base" | grep -Eq '^https://[A-Za-z0-9.:-]+$' || { echo 'An HTTPS router origin is required' >&2; exit 2; }
printf '%s' "$page" | grep -Eq '^user[0-9]+\.asp$' || exit 2
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/ttm-access.XXXXXX")
trap 'rm -f "$work/body" "$work/headers"; rmdir "$work"' EXIT
trap 'exit 1' HUP INT TERM
for resource in "$page" user/trusttunnel/status.json user/trusttunnel/transfer.json; do
    # No -k and no redirects: use the trusted router certificate/CA. A private
    # response stays in this 0700 directory and is never printed or uploaded.
    code=$(curl --silent --show-error --proto '=https' --connect-timeout 5 --max-time 10 --max-filesize 1048576 \
        --cookie '' --dump-header "$work/headers" --output "$work/body" --write-out '%{http_code}' "$base/$resource")
    case "$code" in
        401|403|302|303) printf 'PASS anonymous request denied: %s (%s)\n' "$resource" "$code";;
        200)
            if grep -Eqi '^content-type:[[:space:]]*text/html' "$work/headers" && grep -q 'Main_Login.asp' "$work/body"; then
                printf 'PASS anonymous request shows login: %s\n' "$resource"
            else printf 'FAIL anonymous resource accessible: %s (response withheld)\n' "$resource" >&2; exit 1; fi;;
        *) printf 'UNKNOWN resource check: %s (%s)\n' "$resource" "$code" >&2; exit 1;;
    esac
done
