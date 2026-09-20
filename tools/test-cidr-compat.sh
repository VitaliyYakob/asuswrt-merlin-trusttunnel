#!/bin/sh
# Pure validation: safe on host and router. Uses only synthetic configurations.
set -eu
TT_TEST_BASE=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
TT_TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TT_TEST_TMP"' EXIT HUP INT TERM
for TT_TEST_CIDR in 10.0.0.0/8 172.16.0.0/12 192.168.50.0/24 192.168.50.17/32; do
    jq --arg cidr "$TT_TEST_CIDR" '.sources=[$cidr]' "$TT_TEST_BASE/examples/policy.example.json" >"$TT_TEST_TMP/policy.json"
    jq -e --arg kind policy -f "$TT_TEST_BASE/addon/share/validate.jq" "$TT_TEST_TMP/policy.json" >/dev/null
done
for TT_TEST_CIDR in 192.168.50.1/24 8.8.8.0/24 172.15.0.0/16 10.0.0.0/7; do
    jq --arg cidr "$TT_TEST_CIDR" '.sources=[$cidr]' "$TT_TEST_BASE/examples/policy.example.json" >"$TT_TEST_TMP/policy.json"
    if jq -e --arg kind policy -f "$TT_TEST_BASE/addon/share/validate.jq" "$TT_TEST_TMP/policy.json" >/dev/null 2>&1; then exit 1; fi
done
for TT_TEST_CIDR in 0.0.0.0/0 203.0.113.0/24 203.0.113.9/32; do
    jq --arg cidr "$TT_TEST_CIDR" '.exclusions=[$cidr]' "$TT_TEST_BASE/examples/endpoint.example.json" >"$TT_TEST_TMP/endpoint.json"
    jq -e --arg kind endpoint -f "$TT_TEST_BASE/addon/share/validate.jq" "$TT_TEST_TMP/endpoint.json" >/dev/null
done
jq '.exclusions=["203.0.113.9/24"]' "$TT_TEST_BASE/examples/endpoint.example.json" >"$TT_TEST_TMP/endpoint.json"
if jq -e --arg kind endpoint -f "$TT_TEST_BASE/addon/share/validate.jq" "$TT_TEST_TMP/endpoint.json" >/dev/null 2>&1; then exit 1; fi
printf 'CIDR validation: PASS (%s)\n' "$(jq --version)"
