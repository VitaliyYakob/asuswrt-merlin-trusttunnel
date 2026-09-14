#!/bin/sh
# These helpers perform filesystem operations only; no router commands.
tt_backup_private() {
    [ ! -L "$1" ] || { tt_error 'refusing a symlinked configuration'; return 1; }
    [ -e "$1" ] || return 0
    [ -f "$1" ] && [ ! -L "$1.previous" ] && [ ! -d "$1.previous" ] || {
        tt_error 'invalid configuration backup destination'; return 1;
    }
    TT_BACKUP_TMP=$(mktemp "$1.previous.XXXXXX") || return 1
    if cp "$1" "$TT_BACKUP_TMP" && chmod 600 "$TT_BACKUP_TMP" && mv -f "$TT_BACKUP_TMP" "$1.previous"; then
        return 0
    fi
    rm -f "$TT_BACKUP_TMP"
    tt_error 'configuration backup failed; active configuration preserved'
    return 1
}

tt_backup_install() {
    TT_INSTALL_DEST=$1; TT_INSTALL_INIT=$2
    TT_INSTALL_BACKUP=
    TT_INSTALL_HAS_FILES=0
    for TT_INSTALL_ITEM in lib share web trusttunnel.sh trusttunnel_page.asp config/LAB_ONLY_ACKNOWLEDGED; do
        [ ! -L "$TT_INSTALL_DEST/$TT_INSTALL_ITEM" ] || {
            tt_error 'refusing a symlinked installation target'; return 1;
        }
        [ ! -e "$TT_INSTALL_DEST/$TT_INSTALL_ITEM" ] || TT_INSTALL_HAS_FILES=1
    done
    [ ! -L "$TT_INSTALL_INIT" ] || { tt_error 'refusing a symlinked init script'; return 1; }
    [ ! -e "$TT_INSTALL_INIT" ] || TT_INSTALL_HAS_FILES=1
    [ "$TT_INSTALL_HAS_FILES" -eq 1 ] || return 0
    [ ! -L "$TT_INSTALL_DEST/install-backups" ] || return 1
    mkdir -p "$TT_INSTALL_DEST/install-backups" || return 1
    chmod 700 "$TT_INSTALL_DEST/install-backups" || return 1
    TT_INSTALL_BACKUP=$(mktemp -d "$TT_INSTALL_DEST/install-backups/install-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    chmod 700 "$TT_INSTALL_BACKUP" || return 1
    for TT_INSTALL_ITEM in lib share web trusttunnel.sh trusttunnel_page.asp; do
        [ ! -e "$TT_INSTALL_DEST/$TT_INSTALL_ITEM" ] || cp -Rp "$TT_INSTALL_DEST/$TT_INSTALL_ITEM" "$TT_INSTALL_BACKUP/" || return 1
    done
    if [ -f "$TT_INSTALL_DEST/config/LAB_ONLY_ACKNOWLEDGED" ]; then
        mkdir -p "$TT_INSTALL_BACKUP/config" && cp -p "$TT_INSTALL_DEST/config/LAB_ONLY_ACKNOWLEDGED" "$TT_INSTALL_BACKUP/config/" || return 1
    fi
    [ ! -f "$TT_INSTALL_INIT" ] || cp -p "$TT_INSTALL_INIT" "$TT_INSTALL_BACKUP/S99trusttunnel" || return 1
}
