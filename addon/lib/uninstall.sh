#!/bin/sh
# Only fixed addon paths and explicitly marked setup directories are removable.
tt_uninstall_paths() {
    for TT_U_PATH in "$TT_ROOT/jffs/addons/trusttunnel" "$TT_CONFIG" "$TT_RUN" "$TT_PUBLIC" \
        "$TT_ROOT/opt/trusttunnel" "$TT_ROOT/opt/trusttunnel/bin"; do
        [ ! -L "$TT_U_PATH" ] || { tt_error 'symlinked addon path; removal refused'; return 1; }
    done
}
tt_uninstall_plan() {
    tt_uninstall_paths || return 1
    printf '%s\n' 'REMOVE integration: owned process, routes/firewall, VPN page, marked hook/menu entries, TrustTunnelMerlin cron, owned init script.'
    printf '%s\n' "PURGE private data/code/backups: $TT_ROOT/jffs/addons/trusttunnel" "PURGE runtime: $TT_RUN"
    for TT_U_FILE in "$TT_ROOT/opt/trusttunnel/bin"/*; do
        [ -e "$TT_U_FILE" ] || [ -L "$TT_U_FILE" ] || continue
        case "${TT_U_FILE##*/}" in
            trusttunnel_client|trusttunnel_client.sha256|trusttunnel_client.previous|trusttunnel_client.previous.sha256)
                printf 'PURGE verified client file: %s\n' "$TT_U_FILE";;
            *) printf 'RETAIN unknown client file: %s\n' "$TT_U_FILE";;
        esac
    done
    for TT_U_DIR in "$TT_ROOT"/opt/ttm-setup-* "$TT_ROOT"/opt/trusttunnel-install-* "$TT_ROOT"/tmp/ttm-connect-probe.* "$TT_ROOT"/tmp/ttm-alpha5-trial.*; do
        [ -d "$TT_U_DIR" ] || continue
        if tt_uninstall_marked "$TT_U_DIR"; then printf 'PURGE marked staging: %s\n' "$TT_U_DIR"
        else printf 'RETAIN unmarked staging: %s\n' "$TT_U_DIR"; fi
    done
    printf '%s\n' 'RETAIN shared Entware packages, other addons, Wi-Fi/NVRAM, shared system logs, /tmp/trusttunnel-menu.lock until reboot, and files downloaded to other devices.'
    printf '%s\n' 'Dry run does not stop VPN, load modules, change files or query secrets. Purge cannot securely erase flash media.'
    tt_uninstall_client_check
}
tt_uninstall_marked() {
    [ ! -L "$1" ] && [ -f "$1/.trusttunnel-owned" ] && [ ! -L "$1/.trusttunnel-owned" ] &&
        [ "$(cat "$1/.trusttunnel-owned")" = trusttunnel-merlin-staging-v1 ]
}
tt_uninstall_no_mounts() {
    [ -r "$TT_PROC/mounts" ] || { tt_error 'cannot audit mounts'; return 1; }
    if awk -v path="$1" '$2==path || index($2,path "/")==1 {found=1} END {exit !found}' "$TT_PROC/mounts"; then
        tt_error 'mount inside removal path; removal refused'; return 1
    fi
}
tt_uninstall_client_check() {
    for TT_U_SUFFIX in '' .previous; do
        TT_U_BIN="$TT_ROOT/opt/trusttunnel/bin/trusttunnel_client$TT_U_SUFFIX"
        [ -e "$TT_U_BIN" ] || [ -L "$TT_U_BIN" ] || continue
        [ -f "$TT_U_BIN" ] && [ ! -L "$TT_U_BIN" ] && [ -f "$TT_U_BIN.sha256" ] && [ ! -L "$TT_U_BIN.sha256" ] || {
            tt_error 'unverified client file; preserve it or repair its installation record before purge'; return 1;
        }
        TT_U_DIGEST=$(cat "$TT_U_BIN.sha256")
        printf '%s' "$TT_U_DIGEST" | grep -Eq '^[0-9a-f]{64}$' &&
            [ "$(sha256sum "$TT_U_BIN" | awk '{print $1}')" = "$TT_U_DIGEST" ] || {
            tt_error 'client digest changed; purge refused'; return 1;
        }
    done
}
tt_uninstall_settings() {
    [ ! -L "$TT_CUSTOM" ] || { tt_error 'symlinked shared settings'; return 1; }
    [ -f "$TT_CUSTOM" ] || return 0
    grep -q '^ttm_policy ' "$TT_CUSTOM" || return 0
    cp -p "$TT_CUSTOM" "$TT_RUN/custom-settings.before-uninstall" || return 1
    TT_U_SETTINGS=$(mktemp "${TT_CUSTOM}.ttm-remove.XXXXXX") || return 1
    if cp -p "$TT_CUSTOM" "$TT_U_SETTINGS" && awk '$1!="ttm_policy"' "$TT_CUSTOM" >"$TT_U_SETTINGS" &&
        cmp -s "$TT_CUSTOM" "$TT_RUN/custom-settings.before-uninstall" && mv -f "$TT_U_SETTINGS" "$TT_CUSTOM"; then return 0; fi
    rm -f "$TT_U_SETTINGS"; return 1
}
tt_uninstall_files() {
    # Called only after integration removal and its audit, under the controller lock.
    [ "$1" = purge ] || return 0
    for TT_U_SUFFIX in '' .previous; do
        rm -f "$TT_ROOT/opt/trusttunnel/bin/trusttunnel_client$TT_U_SUFFIX" \
            "$TT_ROOT/opt/trusttunnel/bin/trusttunnel_client$TT_U_SUFFIX.sha256" || return 1
    done
    rmdir "$TT_ROOT/opt/trusttunnel/bin" "$TT_ROOT/opt/trusttunnel" 2>/dev/null || :
    for TT_U_DIR in "$TT_ROOT"/opt/ttm-setup-* "$TT_ROOT"/opt/trusttunnel-install-* "$TT_ROOT"/tmp/ttm-connect-probe.* "$TT_ROOT"/tmp/ttm-alpha5-trial.*; do
        [ -d "$TT_U_DIR" ] || continue
        tt_uninstall_marked "$TT_U_DIR" || continue
        tt_uninstall_no_mounts "$TT_U_DIR" || return 1
        rm -rf "$TT_U_DIR" || return 1
    done
    # These are dedicated addon directories; never delete their parent directories.
    rm -rf "$TT_ROOT/jffs/addons/trusttunnel" "$TT_RUN" || return 1
}
tt_uninstall_no_marker() {
    [ -e "$1" ] || { [ ! -L "$1" ]; return; }
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    grep -qF "$2" "$1" 2>/dev/null
    [ "$?" -eq 1 ]
}
tt_uninstall_audit() {
    if tt_pid_matches || [ -e "$TT_OWNED" ]; then return 1; fi
    TT_U_CRON=$(cru l) || return 1
    printf '%s\n' "$TT_U_CRON" | grep -q '#TrustTunnelMerlin#' && return 1
    for TT_U_HOOK in services-start service-event wan-event firewall-start nat-start services-stop; do
        tt_uninstall_no_marker "$TT_ROOT/jffs/scripts/$TT_U_HOOK" '# BEGIN trusttunnel-merlin' &&
            tt_uninstall_no_marker "$TT_ROOT/jffs/scripts/$TT_U_HOOK" '# END trusttunnel-merlin' || return 1
    done
    for TT_U_PAGE in "$TT_ROOT"/www/user/user*.asp; do
        tt_uninstall_no_marker "$TT_U_PAGE" '<!-- trusttunnel-merlin-page-v1 -->' || return 1
    done
    for TT_U_MENU in "$TT_ROOT/www/require/modules/menuTree.js" "$TT_ROOT/tmp/menuTree.js"; do
        tt_uninstall_no_marker "$TT_U_MENU" '/* trusttunnel-merlin */' || return 1
    done
    for TT_U_ASSET in status.json transfer.json trusttunnel.js connection.js transfer.js trusttunnel.css; do
        [ ! -e "$TT_PUBLIC/$TT_U_ASSET" ] || return 1
    done
    tt_uninstall_no_marker "$TT_CUSTOM" 'ttm_policy ' || return 1
    [ ! -e "$TT_U_INIT" ]
}
tt_uninstall() {
    TT_U_MODE=$1
    tt_uninstall_paths || return 1
    [ ! -e "$TT_CONFIG/transaction" ] || { tt_error 'confirm or roll back the pending transaction first'; return 1; }
    TT_U_INIT="$TT_ROOT/opt/etc/init.d/S99trusttunnel"
    if [ -e "$TT_U_INIT" ] || [ -L "$TT_U_INIT" ]; then
        [ ! -L "$TT_U_INIT" ] && grep -qx 'CTL=/jffs/addons/trusttunnel/trusttunnel.sh' "$TT_U_INIT" || {
            tt_error 'init script ownership is unknown'; return 1;
        }
    fi
    if [ "$TT_U_MODE" = purge ]; then
        [ ! -L "$TT_ROOT/jffs/addons/trusttunnel/.trusttunnel-owned" ] &&
            [ -f "$TT_ROOT/jffs/addons/trusttunnel/.trusttunnel-owned" ] &&
            [ "$(cat "$TT_ROOT/jffs/addons/trusttunnel/.trusttunnel-owned")" = trusttunnel-merlin-addon-v1 ] || {
            tt_error 'install this release before purge to establish ownership'; return 1;
        }
        tt_uninstall_no_mounts "$TT_ROOT/jffs/addons/trusttunnel" && tt_uninstall_no_mounts "$TT_RUN" &&
            tt_uninstall_no_mounts "$TT_ROOT/opt/trusttunnel" && tt_uninstall_client_check || return 1
        for TT_U_DIR in "$TT_ROOT"/opt/ttm-setup-* "$TT_ROOT"/opt/trusttunnel-install-* "$TT_ROOT"/tmp/ttm-connect-probe.* "$TT_ROOT"/tmp/ttm-alpha5-trial.*; do
            if tt_uninstall_marked "$TT_U_DIR"; then tt_uninstall_no_mounts "$TT_U_DIR" || return 1; fi
        done
    fi
    # Failure retains the controller/configuration so cleanup can be retried.
    tt_disable && tt_hooks remove && tt_unmount_ui && tt_uninstall_settings || return 1
    cru d TrustTunnelMerlin || return 1
    rm -f "$TT_U_INIT" || return 1
    if ! tt_uninstall_audit; then
        tt_error 'integration cleanup incomplete; files retained'; return 1
    fi
    tt_uninstall_files "$TT_U_MODE" || return 1
    printf '%s\n' 'Integration removed; ordinary Merlin routing restored.'
    if [ "$TT_U_MODE" = purge ]; then
        printf '%s\n' 'Private configuration, addon backups/code, runtime and verified client files removed. Unmarked/unknown files and shared packages retained.'
    else printf '%s\n' 'Configuration, code, backups and client retained for reinstall.'; fi
}
