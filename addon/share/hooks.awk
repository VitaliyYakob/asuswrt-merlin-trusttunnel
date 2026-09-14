# Idempotently replace only this addon's tagged block; insert before early exit.
function body( x) {
    if (mode == "remove") return
    print "# BEGIN trusttunnel-merlin"
    while ((getline x < bodyfile) > 0) print x
    close(bodyfile)
    print "# END trusttunnel-merlin"
}
BEGIN { skipping=0; inserted=0 }
NR==1 {
    if ($0 ~ /^#!/) {print; body(); inserted=1; next}
    print "#!/bin/sh"; body(); inserted=1
}
$0=="# BEGIN trusttunnel-merlin" {if (skipping) exit 2; skipping=1; next}
$0=="# END trusttunnel-merlin" {if (!skipping) exit 2; skipping=0; next}
!skipping {print}
END {
    if (skipping) exit 2
    if (!inserted) {print "#!/bin/sh"; body()}
}
