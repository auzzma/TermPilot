#!/usr/bin/env python3
"""Package build sources using repository ignore rules, even from a source export."""
from pathlib import Path
import os
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)

def normalize(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ''
    return info

# An empty, temporary Git index evaluates only the shipped .gitignore rules.
# This also works when rebuilding CorrespondingSource without a .git directory,
# and never reads/modifies the user's index or applies their global exclusions.
with tempfile.TemporaryDirectory(prefix='TermPilot-source-index-') as temporary:
    subprocess.run(['git', '-c', 'init.templateDir=', 'init', '--quiet', temporary], check=True)
    listing = subprocess.check_output([
        'git', '-c', f'core.excludesFile={os.devnull}',
        f'--git-dir={Path(temporary) / ".git"}', f'--work-tree={ROOT}',
        'ls-files', '--others', '--exclude-standard', '-z',
    ], cwd=ROOT)
    names = sorted(os.fsdecode(name) for name in listing.split(b'\0') if name)

with tarfile.open(output, 'w:gz') as archive:
    for name in names:
        path = ROOT / name
        if path.is_symlink() or not path.is_file() or path.resolve() == output:
            continue
        archive.add(path, arcname='TermPilot/' + name, recursive=False, filter=normalize)
print(output)
subprocess.run([sys.executable, str(ROOT / 'scripts/audit-privacy.py'), str(output), '--source'], check=True)
