#!/usr/bin/env python3
"""Local SHA-256 policy demo: mandatory hash on ingest, strict small read,
fast large read. Metadata fast checks are NOT cryptographic verification.
Not a complete crash-safe CAS/database coordinator.
"""
from __future__ import annotations
import hashlib
from pathlib import Path

DEFAULT_THRESHOLD = 2 * 1024 * 1024 * 1024


def sha256_stream(path: Path, chunk: int = 1024*1024) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(chunk), b''):
            h.update(b)
    return h.hexdigest()


def ingest_baseline(path: Path) -> dict:
    """One required full digest at ingest, not duplicated immediately afterwards."""
    st = path.stat()
    return {'original_sha256':sha256_stream(path),
            'expected_size':st.st_size,
            'last_mtime_ns':st.st_mtime_ns,
            'last_full_verified':True,
            'last_verification_mode':'initial_full_sha256'}


def validate_logical_open(path: Path, baseline: dict, threshold: int=DEFAULT_THRESHOLD) -> dict:
    """Use this at the *logical open* boundary, never on each small read chunk."""
    stat=path.stat()
    if stat.st_size <= threshold:
        now_sha = sha256_stream(path)
        return {'status':'verified' if now_sha==baseline['original_sha256'] else 'mismatch',
                'mode':'full_sha256', 'sha256':now_sha}
    size_ok=stat.st_size==baseline['expected_size']
    time_ok=stat.st_mtime_ns==baseline['last_mtime_ns']
    return {'status':'quick_checked' if size_ok and time_ok else 'suspicious',
            'mode':'metadata_quick', 'sha256':None,
            'warning':'Metadata quick check is NOT an SHA-256 verification'}

if __name__=='__main__':
    print('DEFAULT_THRESHOLD_BYTES',DEFAULT_THRESHOLD)
