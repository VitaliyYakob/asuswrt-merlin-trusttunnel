# Project instructions

This is an experimental native ASUSWRT-Merlin TrustTunnel CLIENT addon. UI belongs under VPN.
No separate HTTP daemon, REST server, Docker, Node/Python runtime on the router, firmware rebuild, or unrelated multi-VPN manager.

## Ground truth
- No router has been tested. Never mark hardware tests PASS from mocks, generated plans or screenshots.
- Primary intended target: RT-AX86U aarch64, actual firmware/kernel compatibility unknown.
- Runtime uses /bin/sh (BusyBox ash), jq, iproute2, iptables/ip6tables and flock.
- Core schema is based on upstream TrustTunnelClient v1.1.5. Verify upstream before adding fields.
- No official client binary is bundled. Never download/execute an unverified latest release.
- Credentials stay in private files, not amng_custom, status, argv, debug prints or the public web directory.

## Changes
Run `make test` and `make preview`; add regressions for every bug fixed. Host tests use Python 3.11+, Node, jq, BusyBox and flock. Do not claim shellcheck or GitHub Actions passed unless actually run.
Do not execute live networking in this development container. TT_ROOT is an offline filesystem sandbox; live commands must refuse it. Mock network tests must override all networking commands after common.sh sets PATH.
No eval, sourcing user configs, global conntrack flush, default route change in main, unscoped deletion, or deletion of shared hooks/settings/menu entries.
Preserve pause-vs-disable semantics: process stop/crash must not intentionally release guards; explicit disable may release traffic. An interface/PID is not a verified VPN connection.
Keep bind-mounted /opt executable realpath handling and close lock FD in the client process. Do not take table/priority/chain/interface ownership when pre-existing objects are unknown.
Policy edits while enabled remain forbidden until a transactional migration design exists. Bridge-wide IPv6 blocking is intentionally disclosed and acknowledged, not device-scoped IPv6 protection.

## Deliverables
Update VERSION, CHANGELOG, docs/STATUS.md and factual docs/TEST-REPORT.md. Maintain sources/attribution and no real credentials in fixtures. CI workflows here are definitions only until a remote CI run is observed.
