#!/usr/bin/env python3
"""Create source archives; excludes Git metadata, credentials and local build output."""
from pathlib import Path
import hashlib
import tarfile
import zipfile

root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
name = f'asuswrt-merlin-trusttunnel-{version}'
out = root / 'dist'
out.mkdir(exist_ok=True)
blocked = {'.git', '__pycache__', '.lab-root', 'dist', 'build', 'Template', 'backups', 'config', 'install-backups'}
allowed = {'addon', 'docs', 'examples', 'tests', 'tools', 'preview', '.github'}
root_files = {'AGENTS.md','README.md','CHANGELOG.md','LICENSE','VERSION','Makefile','install.sh','uninstall.sh','.gitignore'}
files = sorted(p for p in root.rglob('*') if p.is_file() and not p.is_symlink() and (p.relative_to(root).parts[0] in allowed or (len(p.relative_to(root).parts)==1 and p.name in root_files)) and not any(part in blocked for part in p.relative_to(root).parts)
               and p.name not in {'endpoint.json', 'client.toml', 'trusttunnel-endpoint.json', 'trusttunnel-policy.json', '.DS_Store'}
               and p.suffix not in {'.pyc', '.key', '.pem', '.previous'})
with zipfile.ZipFile(out / f'{name}.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in files:
        archive.write(file, Path(name) / file.relative_to(root))
with tarfile.open(out / f'{name}.tar.gz', 'w:gz') as archive:
    for file in files:
        archive.add(file, arcname=str(Path(name) / file.relative_to(root)))
checks = []
for suffix in ('zip', 'tar.gz'):
    file = out / f'{name}.{suffix}'
    checks.append(f'{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}')
(out / 'SHA256SUMS').write_text('\n'.join(checks) + '\n')
print(f'Packaged {len(files)} source/documentation files into {out}')
