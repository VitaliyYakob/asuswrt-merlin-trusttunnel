#!/bin/sh
tt_validate() {
    [ "$#" -eq 2 ] && [ -f "$2" ] && [ ! -L "$2" ] || { tt_error 'expected a regular configuration file'; return 1; }
    TT_V_SIZE=$(wc -c <"$2")
    [ "$TT_V_SIZE" -le 65536 ] || { tt_error 'configuration exceeds 64 KiB'; return 1; }
    # Do not echo parser context: invalid JSON may contain a secret.
    jq -e --arg kind "$1" -f "$TT_BASE/share/validate.jq" "$2" >/dev/null 2>&1 || {
        tt_error "invalid $1 configuration (see the example and schema documentation)"; return 1;
    }
}
tt_import() {
    [ ! -f "$TT_ENABLED" ] || { tt_error 'disable the addon before changing configuration'; return 1; }
    tt_validate "$1" "$2" || return 1
    case "$1" in endpoint) TT_DEST=$TT_ENDPOINT;; policy) TT_DEST=$TT_POLICY;; *) return 1;; esac
    tt_atomic_json "$2" "$TT_DEST"
}
tt_render() {
    tt_validate endpoint "$1" || return 1
    jq -r -f "$TT_BASE/share/render.jq" "$1"
}
tt_render_runtime() {
    tt_validate endpoint "$TT_ENDPOINT" || return 1
    TT_RENDER_TMP=$(mktemp "$TT_RUN/client.toml.XXXXXX") || return 1
    if tt_render "$TT_ENDPOINT" >"$TT_RENDER_TMP" && chmod 600 "$TT_RENDER_TMP" && mv -f "$TT_RENDER_TMP" "$TT_RUN/client.toml"; then
        return 0
    fi
    rm -f "$TT_RENDER_TMP"
    return 1
}
tt_plan() {
    tt_validate policy "$2" || return 1
    jq --arg action "$1" -f "$TT_BASE/share/network.jq" "$2"
}
tt_apply_web_policy() {
    # Only a non-secret, bounded policy is accepted through amng_custom.
    [ -f "$TT_CUSTOM" ] || return 1
    TT_PAYLOAD=$(awk '$1=="ttm_policy" {sub(/^[^ ]+ /,"");print;exit}' "$TT_CUSTOM")
    [ "${#TT_PAYLOAD}" -le 2999 ] && [ -n "$TT_PAYLOAD" ] || { tt_error 'missing or oversized WebUI payload'; return 1; }
    TT_WEB_TMP=$(mktemp "$TT_RUN/web-policy.XXXXXX") || return 1
    if printf '%s' "$TT_PAYLOAD" | base64 -d >"$TT_WEB_TMP" 2>/dev/null && tt_import policy "$TT_WEB_TMP"; then
        rm -f "$TT_WEB_TMP"
        return 0
    fi
    rm -f "$TT_WEB_TMP"
    return 1
}
