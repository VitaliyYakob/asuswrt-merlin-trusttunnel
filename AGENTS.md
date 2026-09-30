# Project instructions

This is an experimental native ASUSWRT-Merlin TrustTunnel CLIENT addon. UI belongs under VPN.
No separate HTTP daemon, REST server, Docker, Node/Python runtime on the router, firmware rebuild, or unrelated multi-VPN manager.

## Ground truth
- Installation, guest packet flow, signed CLI update, pause/resume and alpha.6 purge have been exercised on RT-AX86U / Merlin 3004.388.12_2 / kernel 4.1.52; consult docs/TEST-REPORT.md for the exact scope. Full leak/recovery coverage and the live IPK lifecycle remain unverified. Never mark hardware tests PASS from mocks, generated plans or screenshots.
- Primary target: RT-AX86U aarch64. The distribution support floor is Merlin 3004.388.12; earlier firmware and other models are untested.
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
Policy edits while enabled must use the existing journalled trial/confirm/rollback migration. Never bypass it. Bridge-wide IPv6 blocking is intentionally disclosed and acknowledged, not device-scoped IPv6 protection.

## Deliverables
Update VERSION, CHANGELOG, docs/STATUS.md and factual docs/TEST-REPORT.md. Maintain sources/attribution and no real credentials in fixtures. CI workflows here are definitions only until a remote CI run is observed.
