#!/usr/bin/env python3
"""Build/verify immutable declarative calculation pack manifest."""
import hashlib
import json
from pathlib import Path
from typing import Any

def hash_file(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as src:
        for b in iter(lambda:src.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def create_manifest(directory: Path) -> dict[str,Any]:
    files=[]
    for f in sorted(directory.rglob('*')):
        if f.is_file() and f.name!='manifest.json':
            files.append({'path':f.relative_to(directory).as_posix(),'sha256':hash_file(f)})
    pipeline=json.loads((directory/'pipeline.json').read_text(encoding='utf8'))
    return {'schema_version':'2.0','pack_id':pipeline['pack_id'],'version':pipeline['version'],
      'kind':'calculation','title':pipeline['title'],'requires_engine':'2.0',
      'files':files,'permission_level':'declarative_only',
      'required_primitives':sorted(set(s['op'] for s in pipeline['pipeline'])),
      'signed_by':None,'author':'Lab Workspace V2.0 sample pack'}

def validate_pack_files(directory: Path) -> None:
    manifest=json.loads((directory/'manifest.json').read_text(encoding='utf8'))
    if manifest['permission_level']!='declarative_only':
        raise ValueError('Demo installer only allows declarative packs')
    actual_files={p.relative_to(directory).as_posix() for p in directory.rglob('*') if p.is_file() and p.name!='manifest.json'}
    declared={item['path'] for item in manifest['files']}
    if declared!=actual_files:raise ValueError('Unexpected or missing files')
    for item in manifest['files']:
        rel=Path(item['path'])
        if rel.is_absolute() or '..' in rel.parts or rel.suffix in ('.py','.dll','.exe','.sh','.bat'):
            raise ValueError('Unsafe file path or executable in declarative pack')
        path=directory/rel
        if path.is_symlink():raise ValueError('Symlink forbidden')
        if hash_file(path)!=item['sha256']:raise ValueError('File hash mismatch: '+str(rel))

if __name__=='__main__':
    d=Path(__file__).resolve().parents[1]/'examples/installed_packs/bca-standard-curve/1.0.0'
    (d/'manifest.json').write_text(json.dumps(create_manifest(d),indent=2,ensure_ascii=False)+'\n',encoding='utf8')
    validate_pack_files(d)
    print('VALID pack manifest',len(list(d.iterdir())),'items')
