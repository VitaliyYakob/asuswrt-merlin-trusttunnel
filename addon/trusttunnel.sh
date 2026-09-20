#!/bin/sh
# TrustTunnel Client Addon for ASUSWRT-Merlin. Experimental, disabled by default.
TT_BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
# shellcheck source=lib/common.sh
. "$TT_BASE/lib/common.sh"
# shellcheck source=lib/config.sh
. "$TT_BASE/lib/config.sh"
# shellcheck source=lib/network.sh
. "$TT_BASE/lib/network.sh"
# shellcheck source=lib/service.sh
. "$TT_BASE/lib/service.sh"
# shellcheck source=lib/webui.sh
. "$TT_BASE/lib/webui.sh"
# shellcheck source=lib/transaction.sh
. "$TT_BASE/lib/transaction.sh"
# shellcheck source=lib/transfer.sh
. "$TT_BASE/lib/transfer.sh"
# shellcheck source=lib/diagnostics.sh
. "$TT_BASE/lib/diagnostics.sh"

TT_ACTION=${1:-help}
[ "$#" -eq 0 ] || shift
case "$TT_ACTION" in
    help|--help)
        cat <<'HELP'
TrustTunnel Merlin 0.3.1-alpha.4
Offline (never changes networking):
  validate endpoint|policy FILE
  render ENDPOINT_JSON           # contains credentials; protect redirected output
  plan guard|up|down|disarm POLICY_JSON
  status
  diagnostics                    # allowlisted compatibility report, no credentials
Configuration (TT_ROOT supported for a sandbox):
  import-endpoint FILE
  import-policy FILE             # changes require explicit disable first
Router laboratory only:
  start | restart | pause        # pause retains requested protection
  disable                        # intentionally releases traffic to normal routing
  refresh | wan | shutdown
  recover                        # roll back a pending transaction; retain guards on failure
  install-webui | uninstall-webui
Internal: event TYPE EVENT; hook NAME; apply-web-policy; boot
HELP
        exit 0;;
    validate) [ "$#" -eq 2 ] || tt_die 'usage: validate endpoint|policy FILE'; tt_validate "$1" "$2"; exit $?;;
    render) [ "$#" -eq 1 ] || tt_die 'usage: render ENDPOINT_JSON'; tt_render "$1"; exit $?;;
    plan) [ "$#" -eq 2 ] || tt_die 'usage: plan ACTION POLICY_JSON'; tt_plan "$1" "$2"; exit $?;;
    status) tt_status; exit $?;;
    diagnostics) tt_diagnostics; exit $?;;
    transfer-event)
        [ "$#" -eq 1 ] || exit 1
        tt_live && tt_lock || exit 1
        tt_wire_dispatch "$1"; TT_RESULT=$?
        case "$1" in ttm_begin_*|ttm_part_*) :;; *) tt_publish_status || :;; esac
        exit "$TT_RESULT";;
    event)
        [ "$#" -eq 2 ] || exit 1
        case "$1:$2" in
            start:ttm_begin_*|start:ttm_part_*|start:ttm_commit_*|start:ttm_do_*|start:ttm_confirm_*|start:ttm_rollback_*|start:ttm_abort_*)
                "$TT_BASE/trusttunnel.sh" transfer-event "$2" >/dev/null 2>&1 &
                exit 0;;
            start:ttm_start) TT_DISPATCH=start;;
            start:ttm_pause) TT_DISPATCH=pause;;
            start:ttm_restart) TT_DISPATCH=restart;;
            start:ttm_disable) TT_DISPATCH=disable;;
            start:ttm_policy) TT_DISPATCH=apply-web-policy;;
            *) exit 0;;
        esac
        "$TT_BASE/trusttunnel.sh" "$TT_DISPATCH" >/dev/null 2>&1 &
        exit 0;;
    hook)
        [ "$#" -eq 1 ] || exit 1
        case "$1" in
            services-start) exec "$TT_BASE/trusttunnel.sh" boot;;
            firewall-start|nat-start) exec "$TT_BASE/trusttunnel.sh" refresh;;
            wan-event) exec "$TT_BASE/trusttunnel.sh" wan;;
            *) exit 1;;
        esac;;
    import-endpoint|import-policy)
        [ "$#" -eq 1 ] || tt_die 'a local JSON path is required'
        tt_lock || exit 1
        tt_import "${TT_ACTION#import-}" "$1"
        TT_RESULT=$?
        tt_publish_status || :
        exit "$TT_RESULT";;
    start|restart|pause|disable|refresh|wan|shutdown|install-webui|uninstall-webui|apply-web-policy|boot|recover) :;;
    *) tt_die 'unknown command; use --help';;
esac
[ "$#" -eq 0 ] || tt_die 'unexpected command arguments'
tt_live && tt_lock || exit 1
case "$TT_ACTION" in
    start|restart|pause|disable|uninstall-webui|apply-web-policy)
        [ ! -e "$TT_CONFIG/transaction" ] || tt_die 'pending transaction: confirm in WebUI or run recover';;
esac
TT_RESULT=0
case "$TT_ACTION" in
    recover) tt_transaction_rollback || TT_RESULT=$?;;
    start) tt_start || TT_RESULT=$?;;
    pause) tt_pause || TT_RESULT=$?;;
    restart) tt_stop_process && tt_start || TT_RESULT=$?;;
    disable) tt_disable || TT_RESULT=$?;;
    shutdown) tt_stop_process || TT_RESULT=$?;;
    refresh) tt_refresh || TT_RESULT=$?;;
    wan)
        if tt_pid_matches; then kill -HUP "$TT_PID" || TT_RESULT=$?; fi
        tt_refresh || TT_RESULT=$?;;
    apply-web-policy) tt_apply_web_policy || TT_RESULT=$?;;
    install-webui)
        tt_hooks install && tt_mount_ui || TT_RESULT=$?
        if [ "$TT_RESULT" -eq 0 ]; then
            cru a TrustTunnelMerlin '* * * * * /jffs/addons/trusttunnel/trusttunnel.sh refresh >/dev/null 2>&1' || TT_RESULT=$?
        fi;;
    uninstall-webui)
        tt_disable && tt_hooks remove && tt_unmount_ui || TT_RESULT=$?
        [ "$TT_RESULT" -ne 0 ] || cru d TrustTunnelMerlin;;
    boot)
        tt_transaction_reconcile || TT_RESULT=$?
        tt_mount_ui || TT_RESULT=$?
        cru a TrustTunnelMerlin '* * * * * /jffs/addons/trusttunnel/trusttunnel.sh refresh >/dev/null 2>&1' || TT_RESULT=$?
        tt_refresh || TT_RESULT=$?;;
esac
if [ "$TT_RESULT" -eq 0 ]; then printf '%s:ok\n' "$TT_ACTION" >"$TT_RUN/last-result"
else printf '%s:error\n' "$TT_ACTION" >"$TT_RUN/last-result"; tt_log "$TT_ACTION failed; inspect local logs and read-only diagnostics"; fi
tt_publish_status || :
exit "$TT_RESULT"
