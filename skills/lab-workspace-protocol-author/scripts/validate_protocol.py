#!/usr/bin/env python3
"""Standalone Protocol Pack schema/DAG validator. Requires jsonschema."""
import json
from pathlib import Path
import sys

SCHEMA = Path(__file__).resolve().parent.parent/'references/protocol-v2.schema.json'

def validate(obj):
    import jsonschema
    jsonschema.validate(obj,json.loads(SCHEMA.read_text(encoding='utf8')))
    steps={s['step_id']:s for s in obj['steps']}
    if len(steps)!=len(obj['steps']):raise ValueError('duplicate step_id')
    done=set(); active=set()
    def visit(sid):
        if sid in active:raise ValueError('DAG cycle at '+sid)
        if sid not in steps:raise ValueError('missing dependency '+sid)
        if sid in done:return
        active.add(sid)
        s=steps[sid]
        if s['kind']=='repeat' and not s.get('repeat_max'):raise ValueError('repeat needs bound')
        if s['duration']['source']=='sop' and not s['duration'].get('source_quote'):
            raise ValueError('SOP duration missing source quote')
        if s['duration']['source']=='unknown' and s['duration']['expected_seconds'] is not None:
            raise ValueError('unknown duration cannot have expected time')
        for dep in s['depends_on']:visit(dep)
        active.remove(sid);done.add(sid)
    for sid in steps:visit(sid)
    if obj['status']=='approved' and not obj['review']['approved_by_user']:
        raise ValueError('approved protocol missing user approval')
    return len(steps)

if __name__=='__main__':
    count=validate(json.loads(Path(sys.argv[1]).read_text(encoding='utf8')))
    print('VALID protocol',count,'steps')
