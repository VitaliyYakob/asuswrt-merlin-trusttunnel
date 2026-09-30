#!/bin/sh
# Shared preflight only. No downloads, package changes or networking mutations.
tt_install_firmware_supported() {
    # Support floor, not a claim that every newer model/branch has been tested.
    case "$1" in 3.0.0.4|3.0.0.6) ;; *) return 1;; esac
    printf '%s\n' "$2" | awk -F. -v branch="$1" '
        NF==2 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ {
            ok=(branch=="3.0.0.6" ? $1>0 : ($1>388 || ($1==388 && $2>=12)))
        } END {exit !ok}'
}
tt_install_disabled() {
    for tt_install_path in /jffs/addons/trusttunnel /jffs/addons/trusttunnel/config /opt/trusttunnel /opt/trusttunnel/bin; do
        [ ! -L "$tt_install_path" ] || { echo 'Symlinked addon directory refused' >&2; return 1; }
    done
    for tt_install_state in enabled paused transaction client-update-journal.json; do
        [ ! -e "/jffs/addons/trusttunnel/config/$tt_install_state" ] &&
            [ ! -L "/jffs/addons/trusttunnel/config/$tt_install_state" ] || {
                echo 'Disable VPN and finish pending recovery before installation' >&2; return 1;
            }
    done
    [ ! -e /tmp/trusttunnel/resources-owned ] || {
        echo 'Existing VPN resources must be released with explicit disable first' >&2; return 1;
    }
}
tt_install_platform() {
    [ -z "${TT_ROOT:-}" ] || { echo 'Installation is prohibited with TT_ROOT' >&2; return 1; }
    [ "$(uname -s):$(uname -m)" = Linux:aarch64 ] || { echo 'Linux aarch64 router required' >&2; return 1; }
    # Firmware BusyBox can lack id until Entware dependencies are installed.
    [ "$(awk '/^Uid:/ {print $3}' /proc/self/status)" = 0 ] || { echo 'root required' >&2; return 1; }
    type nvram >/dev/null 2>&1 && nvram get rc_support | grep -qw am_addons || {
        echo 'Merlin Addons API required' >&2; return 1;
    }
    tt_install_firmware_supported "$(nvram get firmver)" "$(nvram get buildno)" || {
        echo 'Minimum supported Merlin firmware: 3004.388.12 (older versions untested)' >&2; return 1;
    }
    [ "$(nvram get jffs2_scripts)" = 1 ] || { echo 'Enable JFFS custom scripts in Merlin first' >&2; return 1; }
    type opkg >/dev/null 2>&1 && [ -d /opt/etc/init.d ] || { echo 'Working Entware is required' >&2; return 1; }
    # opkg already checked the package architecture in maintainer context.
    # Never run another opkg process from inside its scripts/package lock.
    if [ "${1:-}" != --from-ipk ]; then
        opkg print-architecture | awk '$1=="arch" && $2=="aarch64-3.10" {ok=1} END {exit !ok}' || {
            echo 'Entware aarch64-3.10 required' >&2; return 1;
        }
    fi
    tt_install_disabled
}
tt_install_existing_client() {
    # 0: verified owned client to preserve; 1: absent; 2: unknown/corrupt, refuse.
    tt_install_bin=/opt/trusttunnel/bin/trusttunnel_client
    if [ ! -e "$tt_install_bin" ] && [ ! -L "$tt_install_bin" ] && [ ! -e "$tt_install_bin.sha256" ] && [ ! -L "$tt_install_bin.sha256" ]; then return 1; fi
    [ -f "$tt_install_bin" ] && [ ! -L "$tt_install_bin" ] &&
        [ -f "$tt_install_bin.sha256" ] && [ ! -L "$tt_install_bin.sha256" ] || return 2
    tt_install_hash=$(cat "$tt_install_bin.sha256")
    printf '%s' "$tt_install_hash" | grep -Eq '^[a-f0-9]{64}$' &&
        [ "$(sha256sum "$tt_install_bin" | awk '{print $1}')" = "$tt_install_hash" ] || return 2
    # Also allow recovery of a first installation interrupted after the pinned
    # initial CLI was installed, before the addon ownership marker was written.
    [ "$tt_install_hash" = 0eceaaf0c7afd07b10dd66262c7812ec52aa0ed631d65373f58f4b8318fb5869 ] || {
        [ -f /jffs/addons/trusttunnel/.trusttunnel-owned ] && [ ! -L /jffs/addons/trusttunnel/.trusttunnel-owned ] &&
            [ "$(cat /jffs/addons/trusttunnel/.trusttunnel-owned)" = trusttunnel-merlin-addon-v1 ] || return 2
    }
}
