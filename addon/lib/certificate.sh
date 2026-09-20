#!/bin/sh
tt_validate_certificate() (
    # Upstream can fall back to the system store if a supplied X509 cannot be
    # parsed. Reject malformed custom trust data before importing or rendering.
    jq -e '.certificate == ""' "$1" >/dev/null 2>&1 && return 0
    type openssl >/dev/null 2>&1 || {
        tt_error 'openssl is required to validate a custom certificate'; return 1;
    }
    umask 077
    TT_CERT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ttm-cert.XXXXXX") || return 1
    trap 'rm -f "$TT_CERT_DIR/bundle.pem" "$TT_CERT_DIR"/cert-*.pem; rmdir "$TT_CERT_DIR" 2>/dev/null || :' EXIT
    trap 'exit 1' HUP INT TERM
    chmod 700 "$TT_CERT_DIR" || return 1
    if ! jq -j '.certificate' "$1" >"$TT_CERT_DIR/bundle.pem" 2>/dev/null ||
        ! awk -v directory="$TT_CERT_DIR" -f "$TT_BASE/share/certificates.awk" "$TT_CERT_DIR/bundle.pem" 2>/dev/null; then
        tt_error 'invalid custom certificate bundle'; return 1
    fi
    for TT_CERT_FILE in "$TT_CERT_DIR"/cert-*.pem; do
        [ -f "$TT_CERT_FILE" ] || { tt_error 'empty custom certificate bundle'; return 1; }
        openssl x509 -noout -in "$TT_CERT_FILE" >/dev/null 2>&1 || {
            tt_error 'invalid X509 certificate in custom bundle'; return 1;
        }
    done
)
