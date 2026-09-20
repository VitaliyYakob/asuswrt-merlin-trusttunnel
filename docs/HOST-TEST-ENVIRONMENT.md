# Temporary host testing environment

## Rebuilt on 2026-09-20 for 0.3

The previous `/tmp/ttm-test-deps` no longer existed. The same pinned BusyBox 1.37.0 and flock 0.4.0 sources were verified and rebuilt in `/private/tmp/ttm-host-tests.wJHyq1`. Load its `env.sh` for this session. No global installation or router network configuration was changed.

BusyBox ash uses the same Darwin build adjustments described below; `busybox_unstripped` is the tested executable. Browser: bundled Playwright 1.62.1, downloaded Chromium Headless Shell 151.0.7922.34 in the temporary directory. The precise Playwright version and integrity were checked against the official npm registry before defining CI installation.

ShellCheck 0.10.0 was obtained from its official GitHub release (`shellcheck-v0.10.0.darwin.aarch64.tar.xz`), archive SHA256 `bbd2f14826328eee7679da7221f2bc3afb011f6a928b848c80c321f6046ddf81`. `make lint` checks warning/error severity on entry points with their sourced libraries. Informational suggestions are not included in that gate.

The runtime PATH resolves the OpenSSL CLI to `/usr/bin/openssl`, **LibreSSL 3.3.6**; real RSA-OAEP interoperability tests used that implementation. Homebrew OpenSSL 3.6.4 also exists, but its presence is not reported as an Entware/OpenSSL router test. GnuPG was not installed: signature-verifier control-flow tests use a stub and do not verify an official release.

## Historical 2026-09-14 environment

No project files or global installed binaries were changed. Source archives, builds and installed binaries are in this directory.

## Shell checks and locking

Source `/tmp/ttm-test-deps/env.sh` before `make test`.

- BusyBox 1.37.0 source: https://busybox.net/downloads/busybox-1.37.0.tar.bz2
- SHA256 verified against upstream .sha256 file: `3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4`
- Built a minimal BusyBox supporting ash/sh with Xcode Clang on Darwin arm64. `shell/ash.c` and runtime source remain unmodified. Darwin-specific build adjustments: an archiver wrapper writes the standard empty-ar header when there are no members; GNU linker grouping/info flags removed from `scripts/trylink`; `-Wno-error=implicit-function-declaration` allows unused Linux-only library members to compile; native `-Wl,-dead_strip` removes unused functions. The successfully linked unstripped executable is installed as `bin/busybox` because Darwin strip rejects GNU `--remove-section` flags.
- This provides real BusyBox ash syntax/runtime on Darwin. It does not validate the router's kernel, networking, BusyBox version or full collection of applets.
- flock 0.4.0 source: https://github.com/discoteq/flock/releases/download/v0.4.0/flock-0.4.0.tar.xz
- SHA256 verified against the Homebrew formula API: `01bbd497d168e9b7306f06794c57602da0f61ebd463a3210d63c1d8a0513c5cc`
- Built with `./configure --prefix=/tmp/ttm-test-deps`, `make`, `make install`. The source code is unchanged.
- Functional checks passed for exclusive contention, lock release, numeric file descriptor invocation and `-w` syntax.

## Browser

Bundled Node Playwright: 1.62.1. Browser installed using that exact Playwright package: Chrome Headless Shell 151.0.7922.34 (revision 1234), arm64 macOS.

`NODE_PATH` and `PLAYWRIGHT_BROWSERS_PATH` are set by env.sh. JavaScript can call `require('playwright')`, `chromium.launch({headless:true})`, and `page.setContent(html)`.

An offline test page was rendered successfully. Chromium launch requires the tool execution's `require_escalated` on this machine because the sandbox blocks MachPort IPC. No live router or other network configuration was touched. Python Playwright is not installed; use bundled JavaScript Playwright.

## Baseline

`baseline-make-test.txt` contains the actual unedited make-test output. The test commands run on the host; network executor tests replace networking tools with project mocks, as required by AGENTS.md.
