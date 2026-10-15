#!/usr/bin/env python3
"""Validate all example contracts and semantic constraints; no network."""
from __future__ import annotations
import json
from pathlib import Path
import sys
import sqlite3

ROOT=Path(__file__).resolve().parents[1]
try:
    import jsonschema
except ImportError as e:
    raise SystemExit('Requires python -m pip install jsonschema') from e

EXAMPLES={
 'protocol-v2.schema.json':'examples/protocol/bca-to-wb.json',
 'calculation-pack-v2.schema.json':'examples/bca/pipeline.json',
 'calculation-trace-v2.schema.json':'examples/bca/calculation-trace.json',
 'asset-metadata-v2.schema.json':'examples/storage/asset-small.json',
 'sync-event-v2.schema.json':'examples/storage/sync-event.json',
 'remote-storage-policy-v2.schema.json':'examples/storage/cloud-policy-unencrypted.json',
 'image-tool-plan-v2.schema.json':'examples/storage/image-review-plan.json',
 'forms-v2.schema.json':'examples/installed_packs/bca-standard-curve/1.0.0/forms.json',
 'pack-manifest-v2.schema.json':'examples/installed_packs/bca-standard-curve/1.0.0/manifest.json',
}

def validate_examples():
    for name,example in EXAMPLES.items():
        schema=json.loads((ROOT/'contracts'/name).read_text(encoding='utf8'))
        jsonschema.Draft202012Validator.check_schema(schema)
        obj=json.loads((ROOT/example).read_text(encoding='utf8'))
        jsonschema.Draft202012Validator(schema).validate(obj)
    return len(EXAMPLES)


def validate_protocol(p):
    if p['status']=='approved' and not p['review']['approved_by_user']:
        raise ValueError('Unreviewed approved Protocol')
    steps={s['step_id']:s for s in p['steps']}
    if len(steps)!=len(p['steps']):raise ValueError('Duplicate step ID')
    visited=set();stack=set()
    def visit(sid):
        if sid in stack:raise ValueError('Cycle '+sid)
        if sid not in steps:raise ValueError('Missing dependency '+sid)
        if sid in visited:return
        stack.add(sid)
        s=steps[sid]
        d=s['duration']
        if d['source']=='sop' and not d.get('source_quote'):
            raise ValueError('SOP duration missing quote')
        if d['source']=='unknown' and d.get('expected_seconds') is not None:
            raise ValueError('Unknown duration cannot be filled as known')
        if s['kind']=='repeat' and not s.get('repeat_max'):
            raise ValueError('Unbounded repeat')
        for dep in s['depends_on']:visit(dep)
        stack.remove(sid);visited.add(sid)
    for sid in steps: visit(sid)
    return True


def validate_pack(p,primitive_ids):
    if p['status']=='approved' and not p['review']['approved_by_user']:
        raise ValueError('Unreviewed approved Calculation Pack')
    ids=set()
    for s in p['pipeline']:
        if s['step_id'] in ids:raise ValueError('Duplicate node')
        ids.add(s['step_id'])
        if s['op'] not in primitive_ids:
            raise ValueError('unsupported_operations: '+s['op'])
    return True


def validate_forms(forms, pack):
    expected={f['key'] for f in pack['inputs']}
    found={f['key'] for f in forms['fields']}
    if expected!=found:
        raise ValueError(f'Forms inputs mismatch pack inputs: missing={expected-found}, extra={found-expected}')
    pack_outputs={o['key'] for o in pack['outputs']}
    if {o['key'] for o in forms['outputs']}!=pack_outputs:
        raise ValueError('Forms outputs mismatch')
    if any(o.get('show_trace_button') is not True for o in forms['outputs']):
        raise ValueError('Every derived output requires show_trace_button')
    return True


def check_sql():
    c=sqlite3.connect(':memory:')
    c.executescript((ROOT/'db/001_init.sql').read_text(encoding='utf8'))
    return len(c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall())

if __name__=='__main__':
    print('VALID schemas:', validate_examples())
    obj=json.loads((ROOT/'examples/protocol/bca-to-wb.json').read_text())
    validate_protocol(obj)
    print('VALID protocol DAG')
    from importlib.util import spec_from_file_location, module_from_spec
    spec=spec_from_file_location('pack_runtime_demo',ROOT/'python/pack_runtime_demo.py')
    runtime=module_from_spec(spec);sys.modules[spec.name]=runtime;spec.loader.exec_module(runtime)
    pack=json.loads((ROOT/'examples/bca/pipeline.json').read_text())
    validate_pack(pack,runtime.REGISTRY)
    print('VALID CalculationPack ops')
    forms=json.loads((ROOT/'examples/installed_packs/bca-standard-curve/1.0.0/forms.json').read_text())
    validate_forms(forms,pack)
    print('VALID dynamic forms/trace buttons')
    print('VALID SQL tables:',check_sql())
