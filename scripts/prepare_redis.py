#!/usr/bin/env python3
"""Prepare the pinned Redis driver in a build context; run on the build host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from zipfile import ZipFile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--arch', choices=['amd64', 'arm64'], required=True)
parser.add_argument('--context', type=Path, required=True)
args = parser.parse_args()
url = ('https://github.com/gzamboni/tabularis-redis-plugin-go/releases/download/v0.4.1/'
       f'tabularis-redis-plugin-go-linux-{args.arch}.zip')
archive = args.context.parent / f'redis-0.4.1-{args.arch}.zip'
if not archive.exists():
    for endpoint in [url, os.environ.get('GITHUB_PROXY', 'https://ghfast.top/') + url]:
        result = subprocess.run(['curl', '-fLsS', '--connect-timeout', '15', '--max-time', '120',
                                 '--retry', '2', endpoint, '-o', str(archive)], capture_output=True)
        if result.returncode == 0:
            break
    else:
        archive.unlink(missing_ok=True)
        raise SystemExit('Redis driver download failed')
checksums = {
    'amd64': 'd43d93ad44069d5c25094b53b96fc4d13af7ee2c0e0c209b5d467446e0d88d08',
    'arm64': 'bcf2d043a813283a04a72f51345194e7917465d7de171ae9bbb62593ada1cfac',
}
if hashlib.sha256(archive.read_bytes()).hexdigest() != checksums[args.arch]:
    raise SystemExit('Redis driver checksum mismatch')
with ZipFile(archive) as source:
    manifest = json.loads(source.read('manifest.json'))
    assert manifest['id'] == 'redis' and manifest['version'] == '0.4.1'
    executable = manifest['executable']
    assert '/' not in executable and '\\' not in executable
    target = args.context / 'vendor/redis'
    target.mkdir(parents=True, exist_ok=True)
    for name in ['manifest.json', executable, 'LICENSE', 'README.md']:
        (target/name).write_bytes(source.read(name))
    (target/executable).chmod(0o755)
print(f'Redis driver 0.4.1 {args.arch}: SHA256 {hashlib.sha256(archive.read_bytes()).hexdigest()}')
