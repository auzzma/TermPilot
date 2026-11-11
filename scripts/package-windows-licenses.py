#!/usr/bin/env python3
"""Notices for the Windows Tauri adapter and compiled frontend (build-only)."""
import json,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
host=next(s[6:] for s in subprocess.check_output(['rustc','-vV'],text=True).splitlines() if s.startswith('host: '))
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--offline','--format-version','1','--filter-platform',host,'--manifest-path',str(root/'apps/windows/src-tauri/Cargo.toml')],text=True))
index=[]
for p in metadata['packages']:
 source=Path(p['manifest_path']).parent;paths=[]
 if p.get('source') is None:paths=[root/'LICENSE']
 else:
  paths=[f for f in source.iterdir() if f.is_file() and f.name.upper().startswith(('LICENSE','COPYING','NOTICE'))]
  if p.get('license_file') and (source/p['license_file']).is_file():paths.append(source/p['license_file'])
 for f in set(paths):
  dest=out/'Tauri'/f"{p['name']}-{p['version']}"/f.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,dest)
 index.append(dict(name=p['name'],version=p['version'],license=p.get('license'),repository=p.get('repository')))
(out/'Tauri').mkdir(exist_ok=True);(out/'Tauri/dependencies.json').write_text(json.dumps(index,indent=2)+'\n')
frontend=root/'apps/windows';lock=json.loads((frontend/'package-lock.json').read_text());index=[]
for key,p in lock['packages'].items():
 if not key or p.get('dev') or p.get('optional'):continue
 source=frontend/key
 if not source.is_dir():raise RuntimeError(f'Missing npm package {key}')
 name=key.removeprefix('node_modules/').replace('/node_modules/','/')
 target=out/'Frontend'/name
 for f in source.iterdir():
  if f.is_file() and f.name.upper().startswith(('LICENSE','COPYING','NOTICE')):target.mkdir(parents=True,exist_ok=True);shutil.copy2(f,target/f.name)
 index.append(dict(name=name,version=p.get('version'),license=p.get('license')))
(out/'Frontend').mkdir(exist_ok=True);(out/'Frontend/dependencies.json').write_text(json.dumps(index,indent=2)+'\n')
shutil.copy2(frontend/'public/AutocompleteSpecs.LICENSE',out/'AutocompleteSpecs.LICENSE')
print('Collected Windows Tauri and frontend licenses')
