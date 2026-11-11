#!/usr/bin/env python3
"""Collect source dependency notices for the native distribution (build only)."""
from pathlib import Path
import json, shutil, subprocess, sys
ROOT = Path(__file__).resolve().parents[1]
destination = Path(sys.argv[1]).resolve()
destination.mkdir(parents=True, exist_ok=True)
def copy_notice(source, target):
    # SwiftPM marks dependency files read-only. Output notices remain replaceable
    # when the same dependency is encountered from two target graphs.
    if target.exists(): target.chmod(target.stat().st_mode | 0o200)
    shutil.copy2(source, target)
    target.chmod(target.stat().st_mode | 0o200)

host = next(line.removeprefix('host: ') for line in subprocess.check_output(['rustc','-vV'],text=True).splitlines() if line.startswith('host: '))
# Mobile links the RDP crate through the workspace lockfile, not the standalone
# desktop executable's graph. Never require unrelated native-host downloads.
targets = sys.argv[2:] or [host]
packages = []
for target in targets:
    packages += json.loads(subprocess.check_output(['cargo','metadata','--format-version','1','--locked','--offline','--filter-platform',target],cwd=ROOT))['packages']
if not sys.argv[2:]:
    packages += json.loads(subprocess.check_output(['cargo','metadata','--format-version','1','--locked','--offline','--filter-platform',host,'--manifest-path','engines/rdp/Cargo.toml'],cwd=ROOT))['packages']
metadata = {'packages': list({p['id']: p for p in packages}.values())}
index = []
for package in metadata['packages']:
    source = Path(package['manifest_path']).parent
    name = f"{package['name']}-{package['version']}"
    paths = set()
    if package.get('license_file'):
        path = source / package['license_file']
        if path.is_file(): paths.add(path)
    for path in source.rglob('*'):
        if path.is_file() and not path.is_symlink() and path.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
            if not any(part in ('target','.git','node_modules') for part in path.relative_to(source).parts): paths.add(path)
    # Workspace sources have their license at the repository root.
    if source.is_relative_to(ROOT) and package.get('source') is None and not source.is_relative_to(ROOT/'vendor'):
        paths = {ROOT/'LICENSE'}
        if package['name']=='termpilot-engine': paths.add(ROOT/'engines/rust/LICENSE')
    for path in sorted(paths):
        relative = path.relative_to(source) if path.is_relative_to(source) else Path(path.name)
        if relative.name=='LICENSE' and path==ROOT/'engines/rust/LICENSE':relative=Path('LICENSE-AGPL-3.0')
        target = destination/name/relative
        target.parent.mkdir(parents=True,exist_ok=True);copy_notice(path,target)
    index.append(dict(name=package['name'],version=package['version'],license=package.get('license'),repository=package.get('repository'),notices=len(paths)))
swift_checkouts = [] if any('android' in target for target in sys.argv[2:]) else [ROOT/'apps/macos/.build/checkouts', ROOT/'apps/ios/.derived/SourcePackages/checkouts']
for checkouts in swift_checkouts:
  if checkouts.exists():
    for checkout in checkouts.iterdir():
        for path in checkout.glob('*'):
            if path.is_file() and path.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
                target=destination/'Swift'/checkout.name/path.name;target.parent.mkdir(parents=True,exist_ok=True);copy_notice(path,target)
for name,version,license_name in [('libde265','1.1.3','LGPL-3.0-or-later'),('fdk-aac','2.0.3','Fraunhofer FDK AAC license'),('media-codec','0.1.0','MIT')]:
    source=ROOT/('engines/media-codec' if name=='media-codec' else 'vendor/'+name)
    paths=[p for p in source.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE','TERMPILOT-UPSTREAM'))]
    for path in paths:
        target=destination/'Media'/name/path.name;target.parent.mkdir(parents=True,exist_ok=True);copy_notice(path,target)
    index.append(dict(name=name,version=version,license=license_name,notices=len(paths)))
(destination/'dependencies.json').write_text(json.dumps(index,indent=2)+'\n')
print(f'Collected notices for {len(index)} Rust dependencies and native Swift dependencies.')
