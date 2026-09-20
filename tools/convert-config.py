#!/usr/bin/env python3
"""Convert a supported TrustTunnel TOML on the development computer, not on Merlin."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import sys
import tomllib

def convert(source: dict) -> dict:
    endpoint = source.get("endpoint", {})
    tun = source.get("listener", {}).get("tun", {})
    if not isinstance(endpoint, dict) or not isinstance(tun, dict):
        raise ValueError("Unsupported endpoint/listener structure")
    supported = {"hostname", "addresses", "username", "password", "has_ipv6", "skip_verification",
                 "certificate", "upstream_protocol", "anti_dpi", "dns_upstreams", "client_random"}
    if set(endpoint) - supported:
        raise ValueError("Endpoint contains fields not supported by this alpha; inspect locally")
    if endpoint.get("skip_verification", False):
        raise ValueError("Insecure certificate verification settings are not accepted")
    if endpoint.get("client_random"):
        raise ValueError("Custom client_random is not supported")
    if source.get("vpn_mode", "general") != "general":
        raise ValueError("Internal selective routing cannot be silently converted")
    for key in ("hostname", "addresses", "username", "password"):
        if key not in endpoint:
            raise ValueError("Required endpoint fields are missing")
    return {
        "schema": 1, "hostname": endpoint["hostname"], "addresses": endpoint["addresses"],
        "username": endpoint["username"], "password": endpoint["password"],
        "protocol": endpoint.get("upstream_protocol", "http2"),
        "certificate": endpoint.get("certificate") or "",
        # v1.1.5 uses legacy DNS only when the endpoint field is absent;
        # an explicitly empty endpoint list must not acquire another resolver.
        "dns_upstreams": endpoint.get("dns_upstreams", source.get("dns_upstreams", [])),
        "exclusions": source.get("exclusions", []),
        "anti_dpi": endpoint.get("anti_dpi", False), "mtu": tun.get("mtu_size", 1350),
        "wan_if": tun.get("bound_if", "") or "",
    }

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        if args.source.stat().st_size > 65536:
            raise ValueError("Input exceeds 64 KiB")
        with args.source.open("rb") as stream:
            result = convert(tomllib.load(stream))
        # Exclusive creation prevents accidental overwrite; secrets never go to stdout.
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
    except (OSError, ValueError, TypeError):
        print("Conversion failed. Check input compatibility and that the output does not exist. No secret values are printed.", file=sys.stderr)
        return 1
    print("Private endpoint JSON created. Validate with the addon before importing.")
    print("The addon enforces its own routes, DNS handling, TUN name and IPv4-only policy.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
