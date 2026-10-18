#!/bin/sh
# One owned FIFO, bounded binary chunks, no unbounded line buffers or credentials.
set -eu
umask 077
work=$1; output=$2
[ -d "$work" ] && [ ! -L "$work" ] && [ -p "$work/pipe" ] || exit 1
[ -f "$output" ] && [ ! -L "$output" ] || exit 1
cleanup() { rm -f "$work/chunk" "$work/tail" "$work/pipe"; rmdir "$work" 2>/dev/null || :; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Keep one reader descriptor open across dd calls, otherwise the writer could
# see SIGPIPE between chunks. The controller lock FD is closed by the caller.
exec 8<"$work/pipe"
while :; do
    dd bs=4096 count=1 <&8 >"$work/chunk" 2>/dev/null || exit 1
    bytes=$(wc -c <"$work/chunk")
    [ "$bytes" -gt 0 ] || break
    size=$(wc -c <"$output")
    if [ "$((size+bytes))" -gt 1048576 ]; then
        tail -c 524288 "$output" >"$work/tail"
        cat "$work/tail" >"$output"
    fi
    cat "$work/chunk" >>"$output"
done
