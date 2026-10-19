# Project instructions

This is an experimental native ASUSWRT-Merlin TrustTunnel CLIENT addon. UI belongs under VPN.
No separate HTTP daemon, REST server, Docker, Node/Python runtime on the router, firmware rebuild, or unrelated multi-VPN manager.

## Ground truth
- Installation, guest packet flow, signed CLI update, pause/resume and alpha.6 purge have been exercised on RT-AX86U / Merlin 3004.388.12_2 / kernel 4.1.52. Alpha.10 IPK installation over the owned native addon, keep-config package removal and restoration to alpha.9 were exercised; the alpha.10 acceptance run used CLI 1.1.7. Current runtime state is recorded in the later bullets. Consult docs/TEST-REPORT.md for exact scope. Clean IPK setup, package upgrade, purge alpha.10 and full leak/recovery coverage remain unverified. Never mark hardware tests PASS from mocks, generated plans or screenshots.
- Alpha.11 runtime/payload hotfix restored status publication on 2026-10-17 without restarting the client; opkg registration remains alpha.10-1. Host checks passed; no remote CI for alpha.11 has been observed. Consult docs/TEST-REPORT.md before extending hardware or package claims.
- Alpha.12 UI/version hotfix applied on 2026-10-18 without restarting the client or changing config/routes/rules/cron; runtime/payload alpha.12, opkg registration alpha.10-1. Host tests/browser command simulation passed; real WebUI toggle clicks, IPK alpha.12 installation and remote CI remain unverified. See docs/TEST-REPORT.md.
- Alpha.13 IPK upgrade from package alpha.10 / runtime alpha.12 exercised on 2026-10-18: package/runtime/payload/UI alpha.13, CLI 1.1.7 preserved, coreutils-mkfifo added, config/main routes/ip rules/cron preserved, real bidirectional counters observed. An initial missing-mkfifo candidate exercised external operator rollback to package alpha.10 / runtime alpha.12; this is not internal installer or CLI-trial rollback coverage. Clean setup, purge, new CLI trial/rollback, full leak/recovery and native UI clicks remain unverified. CI/attestation scope is recorded in docs/TEST-REPORT.md.
- Alpha.14 traffic-history hotfix applied on 2026-10-19 without restarting the client: runtime/payload/UI alpha.14, opkg registration alpha.13-1. Existing config/CLI/process/network state preserved; old traffic result migrated to private persistent history and published as expired, not current proof. Host/browser checks passed; real reboot, new traffic-check click, IPK alpha.14 and remote CI remain unverified. Delivery-helper failures/rollback scope are recorded in docs/TEST-REPORT.md.
- Later on 2026-10-19, real opkg alpha.13-1 → alpha.14-1 upgrade completed while VPN was already disabled. Package/runtime/payload/UI now alpha.14; 84 source/init files match, all config/CLI files and main routes/ip rules/firewall/cron preserved. Installer left VPN disabled. Package rollback, clean setup, purge alpha.14, real reboot/new traffic and remote CI alpha.14 remain unverified; see docs/TEST-REPORT.md.
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
Update VERSION, CHANGELOG, docs/STATUS.md and factual docs/TEST-REPORT.md. Maintain sources/attribution and no real credentials in fixtures. Remote GitHub Actions CI has been observed passing; consult docs/TEST-REPORT.md for the exact commit and scope. Do not extend that result to later changes without a new run.
