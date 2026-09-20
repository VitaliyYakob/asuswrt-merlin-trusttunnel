#!/bin/sh
# RSA-OAEP blocks contain an encrypted session/index/count header and raw bytes.
# Only ciphertext and random IDs traverse Merlin's logged service-event string.
tt_transfer_publish() {
    TT_X_DIR="$TT_RUN/transfer"
    TT_X_TMP=$(mktemp "$TT_RUN/.transfer-status.XXXXXX") || return 1
    if [ -f "$TT_X_DIR/meta.json" ]; then
        jq --rawfile public_key "$TT_X_DIR/public.pem" '. + {public_key:$public_key}' "$TT_X_DIR/meta.json" >"$TT_X_TMP" || return 1
    else printf '{"state":"idle"}\n' >"$TT_X_TMP"; fi
    mv -f "$TT_X_TMP" "$TT_RUN/transfer.json" || return 1
    if [ -d "$TT_PUBLIC" ]; then
        cp "$TT_RUN/transfer.json" "$TT_PUBLIC/transfer.json.tmp" && chmod 644 "$TT_PUBLIC/transfer.json.tmp" &&
            mv -f "$TT_PUBLIC/transfer.json.tmp" "$TT_PUBLIC/transfer.json" || return 1
    fi
}
tt_transfer_clear() {
    # Explicit files in a private, non-symlink directory; no recursive removal.
    TT_X_DIR="$TT_RUN/transfer"
    [ ! -L "$TT_X_DIR" ] || return 1
    for TT_X_FILE in private.pem public.pem meta.json meta.next cipher.hex cipher.bin block.bin payload.json incoming.hex; do
        rm -f "$TT_X_DIR/$TT_X_FILE" || return 1
    done
}
tt_wire_dispatch() {
    [ "${#1}" -le 121 ] || return 1
    TT_WIRE=$1
    case "$TT_WIRE" in
        ttm_begin_*) TT_WIRE=${TT_WIRE#ttm_begin_}; tt_transfer_begin "${TT_WIRE%%_*}" "${TT_WIRE#*_}";;
        ttm_part_*)
            TT_WIRE=${TT_WIRE#ttm_part_}; TT_WIRE_ID=${TT_WIRE%%_*}; TT_WIRE=${TT_WIRE#*_}
            tt_transfer_part "$TT_WIRE_ID" "${TT_WIRE%%_*}" "${TT_WIRE#*_}";;
        ttm_commit_*) tt_transfer_finish "${TT_WIRE#ttm_commit_}";;
        ttm_abort_*)
            TT_WIRE_ID=${TT_WIRE#ttm_abort_}; tt_id_valid "$TT_WIRE_ID" || return 1
            [ -f "$TT_RUN/transfer/meta.json" ] || return 0
            jq -e --arg id "$TT_WIRE_ID" '.id==$id' "$TT_RUN/transfer/meta.json" >/dev/null &&
                tt_transfer_clear && tt_transfer_publish;;
        ttm_confirm_*)
            TT_WIRE_ID=${TT_WIRE#ttm_confirm_}; tt_id_valid "$TT_WIRE_ID" && tt_transaction_confirm "$TT_WIRE_ID";;
        ttm_rollback_*)
            TT_WIRE_ID=${TT_WIRE#ttm_rollback_}; tt_id_valid "$TT_WIRE_ID" &&
                jq -e --arg id "$TT_WIRE_ID" '.id==$id' "$TT_CONFIG/transaction/manifest.json" >/dev/null && tt_transaction_rollback;;
        ttm_do_*)
            TT_WIRE=${TT_WIRE#ttm_do_}; TT_WIRE_ID=${TT_WIRE%%_*}; TT_WIRE_ACTION=${TT_WIRE#*_}
            case "$TT_WIRE_ACTION" in start|pause|restart|disable|diagnostics) :;; *) return 1;; esac
            tt_operation_begin "$TT_WIRE_ID" "$TT_WIRE_ACTION"; TT_WIRE_RESULT=$?
            [ "$TT_WIRE_RESULT" -ne 2 ] || return 0
            [ "$TT_WIRE_RESULT" -eq 0 ] || return 1
            TT_WIRE_RESULT=0; TT_FAILURE_CODE=
            if [ -f "$TT_CONFIG/transaction/manifest.json" ] && [ "$TT_WIRE_ACTION" != diagnostics ]; then
                tt_operation_write failed transaction_pending; return 1
            fi
            case "$TT_WIRE_ACTION" in
                start) tt_start || TT_WIRE_RESULT=$?;;
                pause) tt_pause || TT_WIRE_RESULT=$?;;
                restart) tt_stop_process && tt_start || TT_WIRE_RESULT=$?;;
                disable) tt_disable || TT_WIRE_RESULT=$?;;
                diagnostics) tt_diagnostics >"$TT_RUN/diagnostics.json" || TT_WIRE_RESULT=$?;;
            esac
            if [ "$TT_WIRE_RESULT" -eq 0 ]; then tt_operation_write succeeded completed
            else
                case "$TT_FAILURE_CODE" in
                    endpoint_missing|policy_missing|client_missing|forwarding_disabled|dns_missing|dns_conflict|network_changed|offload_unavailable|offload_flush_failed|tun_unavailable|missing_dependency) TT_WIRE_CODE=$TT_FAILURE_CODE;;
                    *) TT_WIRE_CODE=action_failed;;
                esac
                tt_operation_write failed "$TT_WIRE_CODE"
            fi
            return "$TT_WIRE_RESULT";;
        *) return 1;;
    esac
}
tt_transfer_expire() {
    if [ -f "$TT_RUN/transfer/meta.json" ] &&
        ! jq -e --argjson now "$(date +%s)" '.expires_at>$now' "$TT_RUN/transfer/meta.json" >/dev/null; then
        tt_transfer_clear && tt_transfer_publish
    fi
}
tt_transfer_begin() {
    tt_id_valid "$1" || return 1
    case "$2" in ''|*[!0-9]*) return 1;; esac
    [ "$2" -ge 1 ] && [ "$2" -le 512 ] || return 1
    TT_X_ID=$1; TT_X_BLOCKS=$2; TT_X_DIR="$TT_RUN/transfer"
    [ ! -L "$TT_X_DIR" ] || return 1
    tt_transfer_expire || return 1
    if [ -f "$TT_X_DIR/meta.json" ]; then
        jq -e --arg id "$TT_X_ID" --argjson blocks "$TT_X_BLOCKS" '.id==$id and .blocks==$blocks' "$TT_X_DIR/meta.json" >/dev/null || {
            tt_error 'another browser transfer is active'; return 1;
        }
        tt_transfer_publish; return $?
    fi
    [ ! -f "$TT_RUN/operations/$TT_X_ID.json" ] || return 1
    type openssl >/dev/null 2>&1 || { tt_error 'OpenSSL is required for private browser saves'; return 1; }
    mkdir -p "$TT_X_DIR" && chmod 700 "$TT_X_DIR" || return 1
    tt_transfer_clear || return 1
    if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TT_X_DIR/private.pem" >/dev/null 2>&1 ||
        ! openssl pkey -in "$TT_X_DIR/private.pem" -pubout -out "$TT_X_DIR/public.pem" >/dev/null 2>&1; then
        tt_transfer_clear; tt_error 'cannot create a private transfer key'; return 1
    fi
    : >"$TT_X_DIR/payload.json"; : >"$TT_X_DIR/cipher.hex"
    jq -n --arg id "$TT_X_ID" --argjson blocks "$TT_X_BLOCKS" --argjson expires "$(($(date +%s)+7200))" \
        '{id:$id,blocks:$blocks,next:0,state:"receiving",expires_at:$expires}' >"$TT_X_DIR/meta.json" || return 1
    tt_transfer_publish
}
tt_transfer_part() {
    tt_id_valid "$1" || return 1
    case "$2" in ''|*[!0-9]*) return 1;; esac
    [ "${#2}" -le 4 ] && [ "${#3}" -le 88 ] && printf '%s' "$3" | grep -Eq '^[0-9a-f]+$' || return 1
    TT_X_ID=$1; TT_X_INDEX=$2; TT_X_HEX=$3; TT_X_DIR="$TT_RUN/transfer"
    [ -f "$TT_X_DIR/meta.json" ] || return 1
    jq -e --arg id "$TT_X_ID" --argjson now "$(date +%s)" '.id==$id and .expires_at>$now and .state=="receiving"' "$TT_X_DIR/meta.json" >/dev/null || return 1
    TT_X_NEXT=$(jq -r .next "$TT_X_DIR/meta.json"); TT_X_BLOCKS=$(jq -r .blocks "$TT_X_DIR/meta.json")
    [ "$TT_X_INDEX" -lt "$((TT_X_BLOCKS*6))" ] || return 1
    # One acknowledged chunk may be retried after a lost HTTP response.
    if [ "$TT_X_INDEX" -eq "$((TT_X_NEXT-1))" ]; then
        [ "$TT_X_HEX" = "$(cat "$TT_X_DIR/incoming.hex")" ] || return 1
        tt_transfer_publish; return $?
    fi
    [ "$TT_X_INDEX" -eq "$TT_X_NEXT" ] || return 1
    TT_X_SIZE=88; [ "$((TT_X_INDEX%6))" -ne 5 ] || TT_X_SIZE=72
    [ "${#TT_X_HEX}" -eq "$TT_X_SIZE" ] || return 1
    printf '%s' "$TT_X_HEX" >>"$TT_X_DIR/cipher.hex" || return 1
    if [ "$((TT_X_INDEX%6))" -eq 5 ]; then
        if ! LC_ALL=C awk -f "$TT_BASE/share/decode-hex.awk" "$TT_X_DIR/cipher.hex" >"$TT_X_DIR/cipher.bin" ||
            ! openssl pkeyutl -decrypt -inkey "$TT_X_DIR/private.pem" -in "$TT_X_DIR/cipher.bin" -out "$TT_X_DIR/block.bin" \
                -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 >/dev/null 2>&1 ||
            [ "$(head -n 1 "$TT_X_DIR/block.bin")" != "TTM1 $TT_X_ID $((TT_X_INDEX/6)) $TT_X_BLOCKS" ]; then
            tt_transfer_clear; tt_transfer_publish; tt_error 'private transfer rejected'; return 1
        fi
        TT_X_BYTES=$(wc -c <"$TT_X_DIR/block.bin")
        [ "$TT_X_BYTES" -le 180 ] || { tt_transfer_clear; tt_transfer_publish; return 1; }
        tail -n +2 "$TT_X_DIR/block.bin" >>"$TT_X_DIR/payload.json" || return 1
        : >"$TT_X_DIR/cipher.hex"
        rm -f "$TT_X_DIR/block.bin" "$TT_X_DIR/cipher.bin"
    fi
    printf '%s' "$TT_X_HEX" >"$TT_X_DIR/incoming.hex" || return 1
    jq '.next+=1' "$TT_X_DIR/meta.json" >"$TT_X_DIR/meta.next" && mv -f "$TT_X_DIR/meta.next" "$TT_X_DIR/meta.json" || return 1
    tt_transfer_publish
}
tt_transfer_finish() {
    tt_id_valid "$1" || return 1
    TT_X_ID=$1; TT_X_DIR="$TT_RUN/transfer"
    # A repeated commit never repeats an already recorded operation.
    [ ! -f "$TT_RUN/operations/$TT_X_ID.json" ] || return 0
    [ -f "$TT_X_DIR/meta.json" ] || return 1
    jq -e --arg id "$TT_X_ID" --argjson now "$(date +%s)" '.id==$id and .expires_at>$now and .next==(.blocks*6)' "$TT_X_DIR/meta.json" >/dev/null || return 1
    TT_X_RESULT=1
    tt_apply_request "$TT_X_ID" "$TT_X_DIR/payload.json" && TT_X_RESULT=0
    tt_transfer_clear && tt_transfer_publish || return 1
    return "$TT_X_RESULT"
}
