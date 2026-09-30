#!/usr/bin/env python3
"""Create source archives; excludes Git metadata, credentials and local build output."""
from pathlib import Path
import hashlib
import tarfile
import zipfile
import importlib.util

spec = importlib.util.spec_from_file_location('build_ipk', Path(__file__).with_name('build-ipk.py'))
ipk_builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipk_builder)

root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
name = f'asuswrt-merlin-trusttunnel-{version}'
out = root / 'dist'
out.mkdir(exist_ok=True)
ipk = ipk_builder.build(root, out)
(root / 'install-online.sh').write_text(ipk_builder.online_installer(root, ipk))
(root / 'install-online.sh').chmod(0o755)
blocked = {'.git', '__pycache__', '.lab-root', 'dist', 'build', 'Template', 'backups', 'config', 'install-backups'}
allowed = {'addon', 'docs', 'examples', 'tests', 'tools', 'preview', 'packaging', '.github'}
root_files = {'AGENTS.md','README.md','CONTRIBUTING.md','CHANGELOG.md','LICENSE','VERSION','Makefile','install.sh','install-online.sh','build-ipk.sh','uninstall.sh','.gitignore','.gitleaks.toml'}
files = sorted(p for p in root.rglob('*') if p.is_file() and not p.is_symlink() and (p.relative_to(root).parts[0] in allowed or (len(p.relative_to(root).parts)==1 and p.name in root_files)) and not any(part in blocked for part in p.relative_to(root).parts)
               and p.name not in {'endpoint.json', 'client.toml', 'trusttunnel-endpoint.json', 'trusttunnel-policy.json', '.DS_Store'}
               and p.suffix not in {'.pyc', '.key', '.pem', '.previous'}
               and not (p.parent.name == 'preview' and p.suffix == '.png'))
with zipfile.ZipFile(out / f'{name}.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in files:
        archive.write(file, Path(name) / file.relative_to(root))
with tarfile.open(out / f'{name}.tar.gz', 'w:gz') as archive:
    for file in files:
        archive.add(file, arcname=str(Path(name) / file.relative_to(root)))
checks = [f'{hashlib.sha256(ipk.read_bytes()).hexdigest()}  {ipk.name}']
for suffix in ('zip', 'tar.gz'):
    file = out / f'{name}.{suffix}'
    checks.append(f'{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}')
(out / 'SHA256SUMS').write_text('\n'.join(checks) + '\n')
print(f'Built IPK for aarch64-3.10: {ipk.name}')
print(f'Packaged {len(files)} source/documentation files into {out}')
