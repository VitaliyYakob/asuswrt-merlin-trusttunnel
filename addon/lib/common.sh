#!/bin/sh
# Filesystem overrides are for offline development, never for live networking.
export PATH="/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
TT_VERSION=0.2.1-alpha.1
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
    tt_dirs || return 1
    command -v flock >/dev/null 2>&1 || { tt_error 'flock is required'; return 1; }
    exec 9>"$TT_RUN/control.lock"
    flock -w 20 9 || { tt_error 'controller is busy'; return 1; }
}
tt_live() {
    [ -z "$TT_ROOT" ] || { tt_error 'live actions are prohibited with TT_ROOT'; return 1; }
    [ "$(id -u)" = 0 ] || { tt_error 'root is required'; return 1; }
    [ -f "$TT_ACK" ] || { tt_error 'experimental live actions are locked; see README'; return 1; }
    command -v nvram >/dev/null 2>&1 && nvram get rc_support | grep -qw am_addons || {
        tt_error 'Merlin Addons API was not detected'; return 1;
    }
}
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
