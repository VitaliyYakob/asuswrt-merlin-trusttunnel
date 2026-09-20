#!/bin/sh
tt_hook_edit() {
    TT_HOOK_NAME=$1; TT_HOOK_MODE=$2
    case "$TT_HOOK_NAME" in services-start|service-event|wan-event|firewall-start|nat-start|services-stop) :;; *) return 1;; esac
    TT_HOOK_DIR="$TT_ROOT/jffs/scripts"
    mkdir -p "$TT_HOOK_DIR" "$TT_CONFIG/hook-backups" || return 1
    TT_HOOK_FILE="$TT_HOOK_DIR/$TT_HOOK_NAME"
    [ ! -L "$TT_HOOK_FILE" ] || { tt_error 'refusing to rewrite a symlinked hook'; return 1; }
    TT_HOOK_TMP=$(mktemp "$TT_HOOK_DIR/.ttm-hook.XXXXXX") || return 1
    TT_HOOK_BODY=$(mktemp "$TT_RUN/hook-body.XXXXXX") || return 1
    case "$TT_HOOK_NAME" in
        service-event) printf '%s\n' '/jffs/addons/trusttunnel/trusttunnel.sh event "$1" "$2" >/dev/null 2>&1' >"$TT_HOOK_BODY";;
        services-stop) printf '%s\n' '/jffs/addons/trusttunnel/trusttunnel.sh shutdown >/dev/null 2>&1' >"$TT_HOOK_BODY";;
        *) printf '/jffs/addons/trusttunnel/trusttunnel.sh hook %s >/dev/null 2>&1 &\n' "$TT_HOOK_NAME" >"$TT_HOOK_BODY";;
    esac
    TT_HOOK_SOURCE=/dev/null
    if [ -f "$TT_HOOK_FILE" ]; then
        TT_HOOK_SOURCE=$TT_HOOK_FILE
        if [ ! -f "$TT_CONFIG/hook-backups/$TT_HOOK_NAME" ] && ! cp -p "$TT_HOOK_FILE" "$TT_CONFIG/hook-backups/$TT_HOOK_NAME"; then
            rm -f "$TT_HOOK_BODY" "$TT_HOOK_TMP"
            tt_error 'hook backup failed; original preserved'
            return 1
        fi
    fi
    if awk -v mode="$TT_HOOK_MODE" -v bodyfile="$TT_HOOK_BODY" -f "$TT_BASE/share/hooks.awk" "$TT_HOOK_SOURCE" >"$TT_HOOK_TMP" &&
        sh -n "$TT_HOOK_TMP" && chmod 755 "$TT_HOOK_TMP" && mv -f "$TT_HOOK_TMP" "$TT_HOOK_FILE"; then
        rm -f "$TT_HOOK_BODY"; return 0
    fi
    rm -f "$TT_HOOK_BODY" "$TT_HOOK_TMP"
    tt_error 'hook update was rejected; original preserved'
    return 1
}
tt_hooks() {
    for TT_HOOK in services-start service-event wan-event firewall-start nat-start services-stop; do
        tt_hook_edit "$TT_HOOK" "$1" || return 1
    done
}
tt_menu() {
    TT_MENU_MODE=$1; TT_MENU_PAGE=${2:-}
    TT_MENU_TARGET=/www/require/modules/menuTree.js
    exec 8>/tmp/trusttunnel-menu.lock
    flock -w 10 8 || return 1
    TT_MENU_TMP=$(mktemp /tmp/ttm-menu.XXXXXX) || return 1
    TT_MENU_SOURCE=$TT_MENU_TARGET
    [ ! -f /tmp/menuTree.js ] || TT_MENU_SOURCE=/tmp/menuTree.js
    if ! awk -v mode="$TT_MENU_MODE" -v page="$TT_MENU_PAGE" -f "$TT_BASE/share/menu.awk" "$TT_MENU_SOURCE" >"$TT_MENU_TMP"; then
        rm -f "$TT_MENU_TMP"; tt_error 'unsupported VPN menu layout; unchanged'; return 1
    fi
    cp "$TT_MENU_SOURCE" "$TT_RUN/menu.previous" || return 1
    if grep -q ' /www/require/modules/menuTree.js ' /proc/mounts; then
        umount "$TT_MENU_TARGET" || { rm -f "$TT_MENU_TMP"; return 1; }
    fi
    mv -f "$TT_MENU_TMP" /tmp/menuTree.js || return 1
    if ! mount -o bind /tmp/menuTree.js "$TT_MENU_TARGET"; then
        cp "$TT_RUN/menu.previous" /tmp/menuTree.js
        mount -o bind /tmp/menuTree.js "$TT_MENU_TARGET" || :
        tt_error 'menu mount failed; rollback attempted'; return 1
    fi
    flock -u 8
}
tt_mount_ui() {
    [ -f /usr/sbin/helper.sh ] || return 1
    # shellcheck disable=SC1091
    . /usr/sbin/helper.sh
    # Reuse only a page carrying our exact marker, never pages matching generic text.
    TT_PAGE=
    for TT_CANDIDATE in /www/user/user*.asp; do
        [ -f "$TT_CANDIDATE" ] || continue
        if grep -qF '<!-- trusttunnel-merlin-page-v1 -->' "$TT_CANDIDATE"; then
            TT_PAGE=${TT_CANDIDATE##*/}; break
        fi
    done
    if [ -z "$TT_PAGE" ]; then
        am_get_webui_page "$TT_BASE/trusttunnel_page.asp"
        TT_PAGE=$am_webui_page
    fi
    printf '%s' "$TT_PAGE" | grep -Eq '^user[0-9]+\.asp$' || { tt_error 'no available WebUI slot'; return 1; }
    cp "$TT_BASE/trusttunnel_page.asp" "/www/user/$TT_PAGE" || return 1
    chmod 644 "/www/user/$TT_PAGE"
    mkdir -p "$TT_PUBLIC" && chmod 755 "$TT_PUBLIC" || return 1
    cp "$TT_BASE/web/trusttunnel.js" "$TT_BASE/web/connection.js" "$TT_BASE/web/transfer.js" "$TT_BASE/web/trusttunnel.css" "$TT_PUBLIC/" || return 1
    chmod 644 "$TT_PUBLIC/trusttunnel.js" "$TT_PUBLIC/connection.js" "$TT_PUBLIC/transfer.js" "$TT_PUBLIC/trusttunnel.css"
    tt_menu install "$TT_PAGE" || return 1
    printf '%s\n' "$TT_PAGE" >"$TT_RUN/page"
    tt_publish_status
}
tt_unmount_ui() {
    tt_menu remove || return 1
    for TT_CANDIDATE in /www/user/user*.asp; do
        [ -f "$TT_CANDIDATE" ] || continue
        if grep -qF '<!-- trusttunnel-merlin-page-v1 -->' "$TT_CANDIDATE"; then rm -f "$TT_CANDIDATE"; fi
    done
    rm -f "$TT_PUBLIC/status.json" "$TT_PUBLIC/transfer.json" "$TT_PUBLIC/trusttunnel.js" "$TT_PUBLIC/connection.js" "$TT_PUBLIC/transfer.js" "$TT_PUBLIC/trusttunnel.css"
    rmdir "$TT_PUBLIC" 2>/dev/null || :
}
