# Changelog

## 0.1.0-alpha.1

Initial independently implemented native Merlin addon, shell controller, policy/endpoint validation,
TOML generator, declarative routing plans, ownership-aware cleanup, hooks/menu integration,
private credential import, frontend, offline preview and host-side tests.

Fixed during initial local verification: JSON-plan syntax, validation failure propagation through
pipelines, canonical executable matching for symlinked /opt, restoration of a lost tunnel route while
the client remains alive, and atomic repositioning of guard jumps before subsequently inserted rules.

No hardware, upstream-client execution or end-to-end VPN tests have been performed.
