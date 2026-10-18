#!/bin/sh
# Manual, signed upstream client updates. The controller lock serializes these
# with refresh/config/uninstall. Guards stay installed during stop and rollback.
TT_RELEASE_API=https://api.github.com/repos/TrustTunnel/TrustTunnelClient/releases
TT_RELEASE_SIGNER=28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6
tt_update_fail() { TT_FAILURE_CODE=$1; tt_error "$2"; return 1; }
tt_update_channel() {
    case "$1" in stable|nightly) :;; *) return 1;; esac
    [ ! -L "$TT_CONFIG/client-channel.json" ] || return 1
    tt_backup_private "$TT_CONFIG/client-channel.json" || return 1
    TT_U_CHANNEL_TMP=$(mktemp "$TT_CONFIG/.channel.XXXXXX") || return 1
    printf '{"channel":"%s"}\n' "$1" >"$TT_U_CHANNEL_TMP"
    mv -f "$TT_U_CHANNEL_TMP" "$TT_CONFIG/client-channel.json" || return 1
    rm -f "$TT_RUN/client-candidate.json"
}
tt_update_get_channel() {
    if [ -f "$TT_CONFIG/client-channel.json" ]; then
        jq -er '.channel|select(.=="stable" or .=="nightly")' "$TT_CONFIG/client-channel.json"
    else printf 'stable\n'; fi
}
tt_update_fetch() {
    # Explicit TLS, deadlines and download limit; never pipe downloads to a shell.
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --max-filesize "$3" --output "$2" "$1" 2>/dev/null &&
        [ "$(wc -c <"$2")" -le "$3" ]
}
tt_update_version() {
    # Execute only the installed binary with its recorded digest; no argv config.
    [ -f "$TT_BIN" ] && [ ! -L "$TT_BIN" ] && [ -f "$TT_BIN.sha256" ] || return 1
    [ "$(sha256sum "$TT_BIN" | awk '{print $1}')" = "$(cat "$TT_BIN.sha256")" ] || return 1
    timeout 5 "$TT_BIN" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-._a-zA-Z0-9]*)?' | head -n 1
}
tt_update_check() (
    tt_live || return 1
    type curl >/dev/null 2>&1 || { tt_update_fail update_dependencies 'curl is required'; return 1; }
    channel=$(tt_update_get_channel) || return 1
    # Permit firewall/WAN refresh while fetching; revalidate under a fresh lock.
    flock -u 9 || return 1
    work=$(mktemp -d "$TT_RUN/.client-check.XXXXXX") || return 1
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    tt_update_fetch "$TT_RELEASE_API?per_page=100" "$work/releases.json" 4194304 || return 1
    jq -e 'type=="array"' "$work/releases.json" >/dev/null 2>&1 || return 1
    jq --arg channel "$channel" -f "$TT_BASE/share/client-releases.jq" "$work/releases.json" >"$work/selected.json" || return 1
    tt_lock && [ "$channel" = "$(tt_update_get_channel)" ] || return 1
    token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    installed=$(tt_update_version) || installed=
    installed_hash=; [ ! -f "$TT_BIN.sha256" ] || installed_hash=$(cat "$TT_BIN.sha256")
    jq -L "$TT_BASE/share" --arg id "$token" --arg channel "$channel" --arg installed "$installed" --arg hash "$installed_hash" --argjson now "$(date +%s)" \
        'include "versions";
        (if .==null then "none" else (.tag|version_relation($installed)) end) as $relation |
        {id:$id,channel:$channel,checked_at:$now,installed_version:$installed,installed_sha256:$hash,
          candidate:.,relation:$relation,state:(if .==null then "not_published" elif $relation=="current" then "current" elif $relation=="newer" then "available" elif $relation=="older" then "older" else "incompatible" end)}' \
        "$work/selected.json" >"$work/result.json" || return 1
    # Search history survives candidate invalidation, channel changes and reboot.
    # It is informational only; installation still requires a fresh bound token.
    jq '{checked_at,channel,state,available_tag:(.candidate.tag//null)}' "$work/result.json" >"$work/history.json" &&
        tt_backup_private "$TT_CONFIG/client-last-check.json" &&
        tt_atomic_json "$work/history.json" "$TT_CONFIG/client-last-check.json" &&
        tt_atomic_json "$work/result.json" "$TT_RUN/client-candidate.json"
)
tt_update_status() {
    TT_U_CHANNEL=$(tt_update_get_channel) || TT_U_CHANNEL=stable
    TT_U_HASH=; [ ! -f "$TT_BIN.sha256" ] || TT_U_HASH=$(cat "$TT_BIN.sha256")
    TT_U_INFO=null
    [ ! -f "$TT_RUN/client-candidate.json" ] || TT_U_INFO=$(jq -c --arg hash "$TT_U_HASH" \
        'if .installed_sha256==$hash then . else null end' "$TT_RUN/client-candidate.json")
    TT_U_INSTALLED=null
    [ ! -f "$TT_CONFIG/client-release.json" ] || TT_U_INSTALLED=$(jq -c --arg hash "$TT_U_HASH" \
        'if .sha256==$hash then . else null end' "$TT_CONFIG/client-release.json")
    TT_U_LAST_CHECK=null
    [ ! -f "$TT_CONFIG/client-last-check.json" ] || TT_U_LAST_CHECK=$(jq -c \
        '{checked_at,channel,state,available_tag}' "$TT_CONFIG/client-last-check.json")
    TT_U_TRIAL=null
    if [ -f "$TT_CONFIG/client-update-journal.json" ] && jq -e '.phase=="trial"' "$TT_CONFIG/client-update-journal.json" >/dev/null; then
        TT_U_TRIAL=$(jq -n --argjson remaining "$(tt_timer_remaining "$TT_CONFIG/client-update-journal.json")" '{remaining_seconds:$remaining}')
    fi
    TT_U_ROLLBACK=false
    if [ -f "$TT_BIN.previous" ] && [ ! -L "$TT_BIN.previous" ] && [ -f "$TT_BIN.previous.sha256" ] && [ ! -L "$TT_BIN.previous.sha256" ] &&
        [ "$(cat "$TT_BIN.previous.sha256")" != "$TT_U_HASH" ] &&
        [ "$(sha256sum "$TT_BIN.previous" | awk '{print $1}')" = "$(cat "$TT_BIN.previous.sha256")" ]; then TT_U_ROLLBACK=true; fi
    TT_U_READY=true
    for TT_U_TOOL in curl gpg tar timeout od; do type "$TT_U_TOOL" >/dev/null 2>&1 || TT_U_READY=false; done
    jq -n --argjson trial "$TT_U_TRIAL" --argjson rollback "$TT_U_ROLLBACK" --arg channel "$TT_U_CHANNEL" --argjson check "$TT_U_INFO" --argjson installed "$TT_U_INSTALLED" --argjson last_check "$TT_U_LAST_CHECK" \
        --argjson ready "$TT_U_READY" --argjson pending "$([ ! -e "$TT_CONFIG/client-update-journal.json" ] && printf false || printf true)" \
        '{channel:$channel,check:$check,installed:$installed,last_check:$last_check,dependencies_ready:$ready,recovery_pending:$pending,trial:$trial,rollback_available:$rollback}'
}
tt_update_candidate_valid() {
    tt_id_valid "$1" && [ -f "$TT_RUN/client-candidate.json" ] &&
        jq -e --arg mode "${2:-upgrade}" --arg id "$1" --arg channel "$(tt_update_get_channel)" --arg hash "$(cat "$TT_BIN.sha256" 2>/dev/null)" --argjson now "$(date +%s)" \
        '.id==$id and .channel==$channel and .installed_sha256==$hash and ((.state=="available") or ($mode=="downgrade" and .state=="older")) and .checked_at<= $now and .checked_at>($now-3600) and .candidate!=null' \
        "$TT_RUN/client-candidate.json" >/dev/null
}
tt_update_verify_binary() (
    [ -f "$1" ] && [ -f "$2" ] || return 1
    ring=$(mktemp -d "$TT_RUN/.client-keyring.XXXXXX") || return 1
    trap 'rm -rf "$ring"' EXIT HUP INT TERM
    timeout 30 gpg --batch --no-options --homedir "$ring" --import "$TT_BASE/share/client-release-key.asc" >/dev/null 2>&1 || return 1
    timeout 30 gpg --batch --no-options --homedir "$ring" --status-fd 1 --verify "$2" "$1" >"$ring/result" 2>/dev/null || return 1
    awk -v signer="$TT_RELEASE_SIGNER" '$1=="[GNUPG:]" && $2=="VALIDSIG" && ($3==signer || $NF==signer) {ok=1} END {exit !ok}' "$ring/result" || return 1
    magic=$(od -An -tx1 -N6 "$1" | tr -d ' \n')
    machine=$(od -An -tu1 -j18 -N2 "$1" | awk 'NF>=2 {print $1 ":" $2; exit}')
    [ "$magic" = 7f454c460201 ] && [ "$machine" = 183:0 ]
)
tt_update_unpack() {
    # Extract ONLY two known regular members through stdout, never tar -x to disk.
    # Reject duplicate members, traversal, symlinks, hard links and oversize files.
    printf '%s' "$4" | grep -Eq '^trusttunnel_client-[A-Za-z0-9][A-Za-z0-9._-]{0,95}-linux-aarch64$' || return 1
    timeout 30 tar -tzf "$1" >"$3/members" && timeout 30 tar -tvzf "$1" >"$3/types" || return 1
    for TT_U_MEMBER in "$4/trusttunnel_client" "$4/trusttunnel_client.sig"; do
        [ "$(grep -Fxc "$TT_U_MEMBER" "$3/members")" -eq 1 ] || return 1
        awk -v member="$TT_U_MEMBER" '$NF==member {n++; if(substr($1,1,1)!="-" || $3>67108864) bad=1} END {exit !(n==1 && !bad)}' "$3/types" || return 1
    done
    timeout 30 tar -xOzf "$1" "$4/trusttunnel_client" >"$2" &&
        timeout 30 tar -xOzf "$1" "$4/trusttunnel_client.sig" >"$3/client.sig" &&
        [ "$(wc -c <"$2")" -le 67108864 ] && [ "$(wc -c <"$3/client.sig")" -le 16384 ]
}
tt_update_recover() {
    [ -e "$TT_CONFIG/client-update-journal.json" ] || return 0
    [ ! -L "$TT_CONFIG/client-update-journal.json" ] || return 1
    if [ "${1:-}" != force ] && jq -e '.phase=="trial"' "$TT_CONFIG/client-update-journal.json" >/dev/null &&
        [ "$(tt_timer_remaining "$TT_CONFIG/client-update-journal.json")" -gt 0 ]; then return 0; fi
    TT_U_OLD_HASH=$(jq -er '.previous_sha256|select(test("^[a-f0-9]{64}$"))' "$TT_CONFIG/client-update-journal.json") || return 1
    [ -f "$TT_BIN.previous" ] && [ ! -L "$TT_BIN.previous" ] &&
        [ "$(sha256sum "$TT_BIN.previous" | awk '{print $1}')" = "$TT_U_OLD_HASH" ] || return 1
    [ ! -L "$TT_BIN" ] && [ ! -L "$TT_BIN.sha256" ] && [ ! -L "$TT_CONFIG/client-release.json" ] &&
        [ ! -L "$TT_CONFIG/client-release.json.previous" ] || return 1
    for TT_U_DEST in "$TT_BIN.sha256" "$TT_CONFIG/client-release.json" "$TT_CONFIG/client-release.json.previous"; do
        [ ! -e "$TT_U_DEST" ] || [ -f "$TT_U_DEST" ] || return 1
    done
    if [ -e "$TT_BIN" ]; then
        TT_U_CURRENT_HASH=$(sha256sum "$TT_BIN" | awk '{print $1}') || return 1
        TT_U_NEXT_HASH=$(jq -er '.next_sha256|select(test("^[a-f0-9]{64}$"))' "$TT_CONFIG/client-update-journal.json") || return 1
        [ "$TT_U_CURRENT_HASH" = "$TT_U_OLD_HASH" ] || [ "$TT_U_CURRENT_HASH" = "$TT_U_NEXT_HASH" ] || return 1
    fi
    tt_stop_process || return 1
    TT_U_RESTORE=$(mktemp "${TT_BIN}.restore.XXXXXX") || return 1
    if ! cp -p "$TT_BIN.previous" "$TT_U_RESTORE" || ! mv -f "$TT_U_RESTORE" "$TT_BIN"; then rm -f "$TT_U_RESTORE"; return 1; fi
    printf '%s\n' "$TT_U_OLD_HASH" >"$TT_BIN.sha256" || return 1
    if [ -f "$TT_CONFIG/client-release.json.previous" ]; then
        cp -p "$TT_CONFIG/client-release.json.previous" "$TT_CONFIG/client-release.json" || return 1
    else rm -f "$TT_CONFIG/client-release.json" || return 1; fi
    rm -f "$TT_CONFIG/client-update-journal.json"
}
tt_update_guards() {
    [ -f "$TT_ENABLED" ] || return 0
    [ -f "$TT_OWNED" ] && tt_validate policy "$TT_POLICY" && cmp -s "$TT_POLICY" "$TT_RUNTIME_POLICY" || return 1
    tt_run_plan guard "$TT_RUNTIME_POLICY" && tt_rpf_loose
}
tt_update_replace() {
    # The candidate is signed/ELF-checked before entry. Validate old ownership
    # before creating a journal so that recovery always has a known safe copy.
    [ -f "$TT_BIN" ] && [ ! -L "$TT_BIN" ] && [ ! -L "$TT_BIN.previous" ] &&
        [ ! -L "$TT_BIN.sha256" ] && [ ! -L "$TT_BIN.previous.sha256" ] || return 1
    for TT_U_DEST in "$TT_BIN.previous" "$TT_BIN.previous.sha256"; do
        [ ! -e "$TT_U_DEST" ] || [ -f "$TT_U_DEST" ] || return 1
    done
    tt_update_guards || return 1
    TT_U_OLD_HASH=$(sha256sum "$TT_BIN" | awk '{print $1}')
    [ "$TT_U_OLD_HASH" = "$(cat "$TT_BIN.sha256")" ] || return 1
    cp -p "$TT_BIN" "$TT_BIN.previous" && printf '%s\n' "$TT_U_OLD_HASH" >"$TT_BIN.previous.sha256" || return 1
    tt_backup_private "$TT_CONFIG/client-release.json" || return 1
    # A previous metadata file must describe this backup, never an older binary.
    [ -e "$TT_CONFIG/client-release.json" ] || rm -f "$TT_CONFIG/client-release.json.previous"
    TT_U_JOURNAL=$(mktemp "$TT_RUN/.client-journal.XXXXXX") || return 1
    if ! jq -n --arg hash "$TT_U_OLD_HASH" --arg next "$(sha256sum "$1" | awk '{print $1}')" '{previous_sha256:$hash,next_sha256:$next}' >"$TT_U_JOURNAL" ||
        ! tt_atomic_json "$TT_U_JOURNAL" "$TT_CONFIG/client-update-journal.json"; then
        rm -f "$TT_U_JOURNAL"; return 1
    fi
    rm -f "$TT_U_JOURNAL"
    if ! tt_stop_process || ! mv -f "$1" "$TT_BIN" || ! chmod 755 "$TT_BIN"; then
        tt_update_recover || return 1
        [ ! -f "$TT_ENABLED" ] || [ -f "$TT_PAUSED" ] || tt_spawn || :
        return 1
    fi
    sha256sum "$TT_BIN" | awk '{print $1}' >"$TT_BIN.sha256" || return 1
    if [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ] && ! { tt_update_guards && tt_spawn; }; then
        if tt_update_recover; then tt_spawn || { : >"$TT_PAUSED"; }; fi
        tt_update_fail update_rolled_back 'new client startup failed; previous binary restored or recovery pending'
        return 1
    fi
    TT_U_METADATA=$(mktemp "$TT_RUN/.client-installed.XXXXXX") || return 1
    if ! jq --argjson now "$(date +%s)" '. + {installed_at:$now}' "$2" >"$TT_U_METADATA" ||
        ! tt_atomic_json "$TT_U_METADATA" "$TT_CONFIG/client-release.json"; then
        rm -f "$TT_U_METADATA"; return 1
    fi
    rm -f "$TT_U_METADATA"
    if [ -f "$TT_ENABLED" ]; then
        TT_U_TIMER=$(tt_timer 300) || return 1
        TT_U_TRIAL=$(mktemp "$TT_RUN/.client-trial.XXXXXX") || return 1
        if ! jq --argjson timer "$TT_U_TIMER" '. + {phase:"trial",timer:$timer}' "$TT_CONFIG/client-update-journal.json" >"$TT_U_TRIAL" ||
            ! tt_atomic_json "$TT_U_TRIAL" "$TT_CONFIG/client-update-journal.json"; then rm -f "$TT_U_TRIAL"; return 1; fi
        rm -f "$TT_U_TRIAL"
    else rm -f "$TT_CONFIG/client-update-journal.json"; fi
    rm -f "$TT_RUN/client-candidate.json"
}
tt_update_install() (
    tt_live || return 1
    [ ! -e "$TT_CONFIG/transaction" ] && [ ! -e "$TT_CONFIG/client-update-journal.json" ] || return 1
    tt_update_candidate_valid "$1" "${2:-upgrade}" || { tt_update_fail update_stale 'check updates again'; return 1; }
    [ "$(uname -m)" = aarch64 ] || return 1
    for tool in curl gpg tar timeout od; do type "$tool" >/dev/null 2>&1 || { tt_update_fail update_dependencies 'curl, GnuPG, tar, timeout and od are required'; return 1; }; done
    # Download/verification can take minutes: never block guard restoration.
    flock -u 9 || return 1
    work=$(mktemp -d "$TT_RUN/.client-update.XXXXXX") || return 1
    stage=
    trap '[ -z "$stage" ] || rm -f "$stage"; rm -rf "$work"' EXIT HUP INT TERM
    jq .candidate "$TT_RUN/client-candidate.json" >"$work/candidate.json" || return 1
    release_id=$(jq -r .release_id "$work/candidate.json")
    tt_update_fetch "$TT_RELEASE_API/$release_id" "$work/release.json" 4194304 || return 1
    jq -s --arg channel "$(tt_update_get_channel)" -f "$TT_BASE/share/client-releases.jq" "$work/release.json" >"$work/rechecked.json" || return 1
    jq -e --slurpfile checked "$work/rechecked.json" '.==$checked[0]' "$work/candidate.json" >/dev/null || return 1
    url=$(jq -r .url "$work/candidate.json"); expected=$(jq -r .sha256 "$work/candidate.json")
    tt_update_fetch "$url" "$work/client.tar.gz" 33554432 || return 1
    [ "$(sha256sum "$work/client.tar.gz" | awk '{print $1}')" = "$expected" ] || return 1
    stage=$(mktemp "${TT_BIN}.next.XXXXXX") || return 1
    archive_name=$(jq -r .name "$work/candidate.json")
    tt_update_unpack "$work/client.tar.gz" "$stage" "$work" "${archive_name%.tar.gz}" && tt_update_verify_binary "$stage" "$work/client.sig" || return 1
    chmod 755 "$stage" || return 1
    version=$(timeout 5 "$stage" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-._a-zA-Z0-9]*)?' | head -n 1)
    [ -n "$version" ] && [ "v$version" = "$(jq -r .tag "$work/candidate.json")" ] || return 1
    jq --arg version "$version" --arg sha "$(sha256sum "$stage" | awk '{print $1}')" \
        '{version:$version,tag,channel,sha256:$sha}' "$work/candidate.json" >"$work/installed.json" || return 1
    tt_lock && tt_update_candidate_valid "$1" "${2:-upgrade}" && [ ! -e "$TT_CONFIG/transaction" ] &&
        [ ! -e "$TT_CONFIG/client-update-journal.json" ] || return 1
    tt_update_replace "$stage" "$work/installed.json"
)

tt_update_confirm() {
    tt_live || return 1
    [ ! -L "$TT_BIN" ] && [ ! -L "$TT_BIN.sha256" ] && [ ! -L "$TT_CONFIG/client-update-journal.json" ] || return 1
    if [ -f "$TT_ENABLED" ]; then [ ! -f "$TT_PAUSED" ] && tt_pid_matches && ip link show tt0 >/dev/null 2>&1 || return 1; fi
    [ ! -e "$TT_CONFIG/transaction" ] && [ -f "$TT_CONFIG/client-update-journal.json" ] || return 1
    jq -e '.phase=="trial"' "$TT_CONFIG/client-update-journal.json" >/dev/null &&
        [ "$(tt_timer_remaining "$TT_CONFIG/client-update-journal.json")" -gt 0 ] || return 1
    TT_U_HASH=$(sha256sum "$TT_BIN" | awk '{print $1}') || return 1
    jq -e --arg hash "$TT_U_HASH" '.next_sha256==$hash' "$TT_CONFIG/client-update-journal.json" >/dev/null || return 1
    [ "$TT_U_HASH" = "$(cat "$TT_BIN.sha256")" ] || return 1
    rm -f "$TT_CONFIG/client-update-journal.json"
}
tt_update_rollback() {
    tt_live && [ ! -e "$TT_CONFIG/transaction" ] && tt_update_guards || return 1
    if [ ! -e "$TT_CONFIG/client-update-journal.json" ]; then
        [ -f "$TT_BIN.previous" ] && [ ! -L "$TT_BIN.previous" ] && [ ! -L "$TT_BIN.previous.sha256" ] || return 1
        TT_U_PREV=$(cat "$TT_BIN.previous.sha256") || return 1
        printf '%s' "$TT_U_PREV" | grep -Eq '^[a-f0-9]{64}$' || return 1
        [ "$(sha256sum "$TT_BIN.previous" | awk '{print $1}')" = "$TT_U_PREV" ] || return 1
        TT_U_HASH=$(sha256sum "$TT_BIN" | awk '{print $1}') || return 1
        [ "$TT_U_HASH" != "$TT_U_PREV" ] && [ "$TT_U_HASH" = "$(cat "$TT_BIN.sha256")" ] || return 1
        TT_U_JOURNAL=$(mktemp "$TT_RUN/.client-rollback.XXXXXX") || return 1
        if ! jq -n --arg prev "$TT_U_PREV" --arg next "$TT_U_HASH" '{previous_sha256:$prev,next_sha256:$next}' >"$TT_U_JOURNAL" ||
            ! tt_atomic_json "$TT_U_JOURNAL" "$TT_CONFIG/client-update-journal.json"; then rm -f "$TT_U_JOURNAL"; return 1; fi
        rm -f "$TT_U_JOURNAL"
    fi
    tt_update_recover force || return 1
    if [ -f "$TT_ENABLED" ] && [ ! -f "$TT_PAUSED" ]; then tt_preflight && tt_spawn; fi
}
