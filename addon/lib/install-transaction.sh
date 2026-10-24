#!/bin/sh
# Filesystem coordinator. Callers own the control lock and supply UI callbacks.
# Previous/new/rejected trees are retained in a private directory for inspection.
tt_install_transaction() (
    source_dir=$1; destination=$2; init_script=$3
    umask 077
    [ ! -L "$destination/install-backups" ] || return 1
    mkdir -p "$destination/install-backups" || return 1
    chmod 700 "$destination/install-backups" || return 1
    work=$(mktemp -d "$destination/install-backups/install-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    mkdir "$work/new" "$work/old" "$work/rejected" || return 1
    printf '%s\n' trusttunnel-merlin-install-v1 >"$work/.trusttunnel-owned"
    : >"$work/touched"
    # Complete staging and syntax checks before the first destination mutation.
    cp -Rp "$source_dir/addon/lib" "$source_dir/addon/share" "$source_dir/addon/web" "$work/new/" || return 1
    cp -p "$source_dir/addon/trusttunnel.sh" "$source_dir/addon/trusttunnel_page.asp" "$source_dir/uninstall.sh" "$work/new/" || return 1
    printf '%s\n' trusttunnel-merlin-addon-v1 >"$work/new/.trusttunnel-owned"
    for file in "$work/new/trusttunnel.sh" "$work/new/uninstall.sh" "$work/new/lib/"*.sh; do
        /bin/sh -n "$file" || return 1
    done
    # Backup config (including permissions) before hooks write their bookkeeping.
    cp -Rp "$destination/config" "$work/config-before" || return 1
    [ ! -L "$init_script" ] || return 1
    [ ! -e "$init_script" ] || cp -p "$init_script" "$work/old/S99trusttunnel" || return 1
    had_install=0
    [ ! -f "$destination/.trusttunnel-owned" ] || had_install=1
    init_temp=$(mktemp "${init_script}.install.XXXXXX") || return 1
    cp "$source_dir/addon/S99trusttunnel" "$init_temp" && chmod 755 "$init_temp" || return 1
    changed=0; committed=0; ui_attempted=0
    cleanup() {
        result=$?
        trap - EXIT HUP INT TERM
        if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then
            set +e
            [ "$ui_attempted" = 0 ] || tt_install_ui_cleanup
            while IFS= read -r item; do
                if [ -e "$work/old/$item" ]; then
                    [ ! -e "$destination/$item" ] || mv "$destination/$item" "$work/rejected/$item"
                    mv "$work/old/$item" "$destination/$item"
                elif [ ! -e "$work/new/$item" ]; then
                    [ ! -e "$destination/$item" ] || mv "$destination/$item" "$work/rejected/$item"
                fi
            done <"$work/touched"
            if [ -e "$work/old/S99trusttunnel" ]; then cp -p "$work/old/S99trusttunnel" "$init_script"
            elif [ "$init_changed" = 1 ]; then mv "$init_script" "$work/rejected/S99trusttunnel"; fi
            # No concurrent configuration writer is admitted while lock is held.
            mv "$destination/config" "$work/rejected/config"
            mv "$work/config-before" "$destination/config"
            if [ "$had_install" = 1 ]; then
                tt_install_ui || printf '%s\n' 'Previous code restored; WebUI repair still required' >&2
            fi
            printf 'Installation failed; previous files restored. Record: %s\n' "$work" >&2
        fi
        [ ! -f "$init_temp" ] || rm -f "$init_temp"
        exit "$result"
    }
    init_changed=0
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    changed=1
    for item in lib share web trusttunnel.sh trusttunnel_page.asp uninstall.sh .trusttunnel-owned; do
        [ ! -L "$destination/$item" ] || exit 1
        printf '%s\n' "$item" >>"$work/touched"
        [ ! -e "$destination/$item" ] || mv "$destination/$item" "$work/old/$item" || exit 1
        mv "$work/new/$item" "$destination/$item" || exit 1
    done
    chmod 755 "$destination/trusttunnel.sh" || exit 1
    if [ ! -f "$destination/config/LAB_ONLY_ACKNOWLEDGED" ]; then
        printf '%s\n' 'Laboratory alpha; not a verified leak-prevention product.' >"$destination/config/LAB_ONLY_ACKNOWLEDGED" || exit 1
    fi
    # Retired manual traffic history: the original is in config-before.
    # Unlink only this exact owned filename; never follow a symlink target.
    rm -f "$destination/config/traffic-check.json" || exit 1
    mv -f "$init_temp" "$init_script" || exit 1
    init_changed=1; ui_attempted=1
    tt_install_ui || exit 1
    # The old RAM record is retired too, but never copied into current status.
    if [ -n "${TT_RUN:-}" ] && [ -e "$TT_RUN/traffic-check.json" ]; then
        [ ! -L "$TT_RUN" ] && [ ! -L "$TT_RUN/traffic-check.json" ] || exit 1
        cp -p "$TT_RUN/traffic-check.json" "$work/traffic-check-runtime.json" || exit 1
        rm -f "$TT_RUN/traffic-check.json" || exit 1
    fi
    committed=1
    printf 'Installation committed. Previous files and configuration: %s\n' "$work"
)
