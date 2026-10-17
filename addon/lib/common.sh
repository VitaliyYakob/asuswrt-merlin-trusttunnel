#!/bin/sh
# Filesystem overrides are for offline development, never for live networking.
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
TT_VERSION=0.3.1-alpha.11
TT_ROOT=${TT_ROOT:-}
TT_CONFIG="$TT_ROOT/jffs/addons/trusttunnel/config"
TT_RUN="$TT_ROOT/tmp/trusttunnel"
TT_PUBLIC="$TT_ROOT/www/user/trusttunnel"
TT_CUSTOM="$TT_ROOT/jffs/addons/custom_settings.txt"
TT_BIN="$TT_ROOT/opt/trusttunnel/bin/trusttunnel_client"
TT_PROC="$TT_ROOT/proc"
TT_SYS="$TT_ROOT/sys"
TT_ENDPOINT="$TT_CONFIG/endpoint.json"
TT_POLICY="$TT_CONFIG/policy.json"
TT_RUNTIME_POLICY="$TT_RUN/owned-policy.json"
TT_ENABLED="$TT_CONFIG/enabled"
TT_PAUSED="$TT_CONFIG/paused"
TT_ACK="$TT_CONFIG/LAB_ONLY_ACKNOWLEDGED"
TT_OWNED="$TT_RUN/resources-owned"

# Never pass secrets to logger or argv. Diagnostics use fixed error messages.
tt_error() { printf 'TrustTunnel: %s\n' "$*" >&2; }
tt_die() { tt_error "$*"; exit 1; }
tt_log() { logger -t trusttunnel-merlin -- "$*" 2>/dev/null || :; }
tt_dirs() {
    umask 077
    mkdir -p "$TT_CONFIG" "$TT_RUN" || return 1
    chmod 700 "$TT_CONFIG" "$TT_RUN" || return 1
}
tt_lock() {
    [ -f "$TT_BASE/trusttunnel.sh" ] || { tt_error 'controller was uninstalled'; return 1; }
    tt_dirs || return 1
    type flock >/dev/null 2>&1 || { tt_error 'flock is required'; return 1; }
    exec 9>"$TT_RUN/control.lock"
    flock -w 20 9 || { tt_error 'controller is busy'; return 1; }
    # A queued action must not resurrect files after a completed purge.
    [ -f "$TT_BASE/trusttunnel.sh" ] || { tt_error 'controller was uninstalled'; return 1; }
}
tt_live() {
    [ -z "$TT_ROOT" ] || { tt_error 'live actions are prohibited with TT_ROOT'; return 1; }
    [ "$(id -u)" = 0 ] || { tt_error 'root is required'; return 1; }
    [ -f "$TT_ACK" ] || { tt_error 'experimental live actions are locked; see README'; return 1; }
    # The native read-only helper is a direct Addons API capability check.
    # Do not make every action depend on a responsive NVRAM daemon.
    if [ -f /usr/sbin/helper.sh ] && grep -Eq '^am_get_webui_page\(\)[[:space:]]*\{' /usr/sbin/helper.sh; then return 0; fi
    type nvram >/dev/null 2>&1 && tt_nvram_get rc_support | grep -qw am_addons || {
        tt_error 'Merlin Addons API was not detected'; return 1;
    }
}
tt_nvram_get() (
    # Read-only, bounded firmware access. A hung reader cannot inherit the
    # controller lock. Discard partial output and briefly suppress repeat calls.
    exec 9>&-
    [ -z "$TT_ROOT" ] || return 1
    [ -d "$TT_RUN" ] && [ ! -L "$TT_RUN" ] || return 1
    umask 077
    now=$(date +%s)
    if [ -f "$TT_RUN/nvram-failed" ] && [ ! -L "$TT_RUN/nvram-failed" ]; then
        failed=$(cat "$TT_RUN/nvram-failed")
        case "$failed" in ''|*[!0-9]*) :;; *)
            if [ "${#failed}" -le 12 ] && [ "$now" -ge "$failed" ] && [ "$((now-failed))" -lt 30 ]; then return 1; fi;;
        esac
    fi
    output=$(mktemp "$TT_RUN/.nvram-read.XXXXXX") || return 1
    trap 'rm -f "$output"' EXIT
    if type timeout >/dev/null 2>&1 && type nvram >/dev/null 2>&1 &&
        timeout -k 1 2 nvram get "$1" >"$output" 2>/dev/null; then
        rm -f "$TT_RUN/nvram-failed"
        cat "$output"
        return $?
    fi
    if [ -d "$TT_RUN" ] && [ ! -L "$TT_RUN" ]; then
        failure=$(mktemp "$TT_RUN/.nvram-failed.XXXXXX") || return 1
        chmod 600 "$failure" && printf '%s\n' "$now" >"$failure" && mv -f "$failure" "$TT_RUN/nvram-failed" || {
            rm -f "$failure"; return 1;
        }
    fi
    return 1
)
tt_atomic_json() {
    # Input is already validated. Temp file is on the destination filesystem.
    TT_AJ_TMP=$(mktemp "${2}.XXXXXX") || return 1
    if jq -S . "$1" >"$TT_AJ_TMP" && chmod 600 "$TT_AJ_TMP" && mv -f "$TT_AJ_TMP" "$2"; then
        return 0
    fi
    rm -f "$TT_AJ_TMP"
    return 1
}
tt_pid_matches() {
    [ -f "$TT_RUN/client.pid" ] && [ -f "$TT_RUN/client.start" ] || return 1
    TT_PID=$(cat "$TT_RUN/client.pid")
    case "$TT_PID" in ''|*[!0-9]*) return 1;; esac
    [ "$TT_PID" -gt 1 ] || return 1
    [ -r "$TT_PROC/$TT_PID/stat" ] || return 1
    # A fixed upstream executable name has no spaces or ')' in comm.
    TT_START=$(awk '{print $22}' "$TT_PROC/$TT_PID/stat")
    [ "$TT_START" = "$(cat "$TT_RUN/client.start")" ] || return 1
    TT_EXE=$(readlink "$TT_PROC/$TT_PID/exe") || return 1
    TT_EXPECTED=$(readlink -f "$TT_BIN") || return 1
    [ "$TT_EXE" = "$TT_EXPECTED" ] || [ "$TT_EXE" = "$TT_EXPECTED (deleted)" ] || return 1
    kill -0 "$TT_PID" 2>/dev/null
}
