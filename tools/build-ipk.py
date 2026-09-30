#!/usr/bin/env python3
"""Build a deterministic Entware IPK containing addon sources, never credentials/CLI."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
NAME = 'asuswrt-merlin-trusttunnel'
ARCH = 'aarch64-3.10'
PREFIX = f'opt/share/{NAME}'
DEPENDENCIES = ('jq-full', 'flock', 'curl', 'ca-bundle', 'openssl-util', 'gnupg',
                'coreutils-id', 'coreutils-sha256sum', 'coreutils-mktemp',
                'coreutils-base64', 'coreutils-od', 'coreutils-stat', 'coreutils-timeout', 'tar')
TOOLS = ('setup-router.sh', 'prepare-entware.sh', 'router-platform.sh',
         'install-client.sh', 'verify-client.sh')


def version(root: Path) -> str:
    value = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-alpha\.\d+)?', value):
        raise ValueError('Invalid release version')
    return value


def tar_gzip(entries: dict[str, tuple[bytes, int]]) -> bytes:
    stream = io.BytesIO()
    directories = set()
    for name in entries:
        directories.update(str(parent) for parent in Path(name).parents if str(parent) != '.')
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.GNU_FORMAT) as archive:
        for name in sorted(directories):
            item = tarfile.TarInfo('./' + name + '/')
            item.type, item.mode, item.mtime = tarfile.DIRTYPE, 0o755, 0
            archive.addfile(item)
        for name, (data, mode) in sorted(entries.items()):
            item = tarfile.TarInfo('./' + name)
            item.size, item.mode, item.mtime = len(data), mode, 0
            archive.addfile(item, io.BytesIO(data))
    compressed = bytearray(gzip.compress(stream.getvalue(), mtime=0))
    # Python 3.11/3.12 can let zlib encode a host-specific OS byte at mtime=0.
    compressed[9] = 255
    return bytes(compressed)


def payload(root: Path) -> dict[str, tuple[bytes, int]]:
    files = sorted((root / 'addon').rglob('*'))
    files += [root / name for name in ('VERSION', 'LICENSE', 'install.sh', 'uninstall.sh')]
    files += [root / 'tools' / name for name in TOOLS]
    entries = {}
    for file in files:
        if file.is_symlink():
            raise ValueError(f'Symlink refused in IPK payload: {file.relative_to(root)}')
        if file.is_dir():
            continue
        relative = file.relative_to(root)
        if file.suffix in {'.pyc', '.key', '.pem', '.previous'} or any(
                part in {'__pycache__', 'config', 'install-backups'} for part in relative.parts):
            raise ValueError(f'Private or generated file refused: {relative}')
        if file.name in {'endpoint.json', 'client.toml', '.DS_Store', 'trusttunnel_client'}:
            raise ValueError(f'Unexpected payload file: {relative}')
        mode = 0o755 if file.suffix == '.sh' or file.name == 'S99trusttunnel' else 0o644
        entries[f'{PREFIX}/{relative.as_posix()}'] = file.read_bytes(), mode
    return entries


def maintainer(root: Path, name: str) -> bytes:
    text = (root / 'packaging' / f'{name}.sh').read_text()
    if name in {'preinst', 'prerm'}:
        functions = (root / 'tools/router-platform.sh').read_text().split('\n', 1)[1]
        anchor = 'tt_install_platform --from-ipk\n' if name == 'preinst' else 'case "${1:-}" in\n'
        text = text.replace(anchor, functions + '\n' + anchor, 1)
    return text.encode()


def build(root: Path, output: Path) -> Path:
    release = version(root)
    data = payload(root)
    control = (f'Package: {NAME}\nVersion: {release}-1\nSection: net\nArchitecture: {ARCH}\n'
               'Maintainer: VitaliyYakob\n'
               f'Source: https://github.com/VitaliyYakob/{NAME}\n'
               f'Depends: {", ".join(DEPENDENCIES)}\n'
               f'Installed-Size: {sum(len(content) for content, _ in data.values())}\n'
               'Description: Экспериментальный нативный клиент TrustTunnel для ASUSWRT-Merlin\n'
               ' Устанавливается выключенным; официальный клиент ARM64 скачивается и проверяется отдельно.\n')
    metadata = {'control': (control.encode(), 0o644), 'conffiles': (b'', 0o644)}
    metadata.update({name: (maintainer(root, name), 0o755) for name in ('preinst', 'postinst', 'prerm')})
    package = tar_gzip({'debian-binary': (b'2.0\n', 0o644),
                        'control.tar.gz': (tar_gzip(metadata), 0o644),
                        'data.tar.gz': (tar_gzip(data), 0o644)})
    output.mkdir(parents=True, exist_ok=True)
    target = output / f'{NAME}_{release}-1_{ARCH}.ipk'
    target.write_bytes(package)
    return target


def online_installer(root: Path, package: Path) -> str:
    text = (root / 'packaging/install-online.sh.in').read_text()
    replacements = {'@VERSION@': version(root), '@IPK@': package.name,
                    '@SHA256@': hashlib.sha256(package.read_bytes()).hexdigest(),
                    '@PLATFORM@': (root / 'tools/router-platform.sh').read_text().split('\n', 1)[1].rstrip()}
    for marker, value in replacements.items():
        text = text.replace(marker, value)
    return text


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--write-online', action='store_true')
    args = parser.parse_args()
    ipk = build(ROOT, args.output)
    if args.write_online:
        target = ROOT / 'install-online.sh'
        target.write_text(online_installer(ROOT, ipk))
        target.chmod(0o755)
    print(f'Built {ipk.name}: {hashlib.sha256(ipk.read_bytes()).hexdigest()}')
