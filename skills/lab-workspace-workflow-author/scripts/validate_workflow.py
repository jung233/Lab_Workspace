#!/usr/bin/env python3
"""Standalone CalculationPack schema, operator, and data-reference validator."""
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent.parent

def validate(obj):
    import jsonschema
    schema=json.loads((ROOT/'references/calculation-pack-v2.schema.json').read_text(encoding='utf8'))
    jsonschema.validate(obj,schema)
    registry=json.loads((ROOT/'references/primitive-registry.json').read_text(encoding='utf8'))
    known=set(registry['primitive_ids'])
    declared={x['key'] for x in obj['inputs']}
    done=set()
    for step in obj['pipeline']:
        sid=step['step_id']
        if sid in done:raise ValueError('duplicate step id')
        if step['op'] not in known:raise ValueError('unsupported_operations: '+step['op'])
        for ref in step['inputs'].values():
            if not isinstance(ref,str) or not ref.startswith('$'):continue
            bits=ref[1:].split('.')
            if bits[0]=='inputs' and (len(bits)<2 or bits[1] not in declared):
                raise ValueError('unknown input: '+ref)
            if bits[0]=='steps' and (len(bits)<3 or bits[1] not in done):
                raise ValueError('forward/missing reference: '+ref)
            if bits[0] not in ('inputs','steps'):
                raise ValueError('unsupported ref: '+ref)
        done.add(sid)
    for out in obj['outputs']:
        bits=out['from_ref'].removeprefix('$').split('.')
        if len(bits)<3 or bits[0]!='steps' or bits[1] not in done:
            raise ValueError('unsupported output: '+out['from_ref'])
    if obj['status']=='approved' and not obj['review']['approved_by_user']:
        raise ValueError('Cannot approve an unreviewed calculation pack')
    return len(done)

if __name__=='__main__':
    print('VALID workflow',validate(json.loads(Path(sys.argv[1]).read_text(encoding='utf8'))),'nodes')
