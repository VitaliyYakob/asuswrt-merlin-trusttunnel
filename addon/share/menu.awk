# Keep other addons' entries intact. Unsupported menu layouts are rejected.
index($0, "/* trusttunnel-merlin */") {next}
{print}
mode!="remove" && !inserted && /url:[[:space:]]*"Advanced_VPNClient_Content.asp"/ {
    print "{url: \"" page "\", tabName: \"TrustTunnel\"}, /* trusttunnel-merlin */"
    inserted=1
}
END {if (mode!="remove" && !inserted) exit 3}
