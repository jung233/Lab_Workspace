#!/usr/bin/env python3
"""Auditable, allowlisted, declarative calculation pack runner (stdlib demo).

This code is a reference implementation, not a validated clinical or wet-lab method.
Only registered operations can execute; no eval, shell or user Python code.
"""
from __future__ import annotations
from decimal import Decimal, getcontext
import hashlib
import json
from pathlib import Path
import platform
import sys

getcontext().prec = 28


def D(x):
    return Decimal(str(x))


def stable(x):
    if isinstance(x, Decimal):
        return str(x)
    if isinstance(x, dict):
        return {k:stable(v) for k,v in x.items()}
    if isinstance(x, list):
        return [stable(v) for v in x]
    return x


def ref_value(ref, context):
    if not isinstance(ref, str) or not ref.startswith('$'):
        return ref
    bits=ref[1:].split('.')
    if bits[0] not in ('inputs','steps'):
        raise ValueError('Illegal reference root: '+bits[0])
    val=context
    for key in bits:
        if not isinstance(val, dict) or key not in val:
            raise ValueError('Missing/forward reference: '+ref)
        val=val[key]
    return val


def record(step, formula, substitution, indata, detail, result, unit=None, warnings=None):
    return {'seq':0, 'op':step['op'], 'expression':formula,
            'substitution':substitution, 'inputs':stable(indata),
            'intermediates':stable(detail),
            'result':{'key':step['step_id'],'value':str(result),'unit':unit},
            'warnings':warnings or []}


def bca_blank(step, args):
    blank=D(args['blank'])
    rows=[]
    for row in args['standards']:
        rows.append({'concentration':str(D(row['concentration'])),
                     'absorbance':str(D(row['absorbance'])-blank)})
    info=record(step,'y_i_corrected = y_i - blank', 'each absorbance minus '+str(blank),
                args,{'corrected_rows':rows},len(rows),None)
    return {'standards':rows},info


def subtract(step,args):
    a,b=D(args['a']),D(args['b'])
    val=a-b
    return {'value':str(val)},record(step,'a-b',f'{a}-{b}',args,{},val,'AU')


def linear_fit(step,args):
    rows=args['standards']
    if len(rows)<2: raise ValueError('Need >=2 standards')
    xs=[D(r['concentration']) for r in rows]
    ys=[D(r['absorbance']) for r in rows]
    if len(set(xs))<2: raise ValueError('Need >=2 distinct x concentrations')
    n=D(len(xs));mx=sum(xs)/n;my=sum(ys)/n
    sxx=sum((x-mx)**2 for x in xs)
    sxy=sum((x-mx)*(y-my) for x,y in zip(xs,ys))
    if sxx==0: raise ValueError('Sxx zero')
    slope=sxy/sxx
    if slope<=0: raise ValueError('Non-positive slope')
    intercept=my-slope*mx
    residuals=[y-(slope*x+intercept) for x,y in zip(xs,ys)]
    rss=sum(v*v for v in residuals)
    sst=sum((y-my)**2 for y in ys)
    r2=D(1)-rss/sst if sst!=0 else D(1) if rss==0 else D(0)
    out={'slope':str(slope),'intercept':str(intercept),'r_squared':str(r2),
         'min_x':str(min(xs)),'max_x':str(max(xs))}
    detail={'xbar':mx,'ybar':my,'sxx':sxx,'sxy':sxy,'rss':rss,'sst':sst,
            'r_squared':r2,'intercept':intercept,'residuals':residuals}
    info=record(step,'slope=Sxy/Sxx;intercept=ybar-slope*xbar;R2=1-RSS/SST',
                f'slope={sxy}/{sxx}; intercept={my}-{slope}*{mx}',args,detail,slope,'AU/(ug/mL)')
    return out,info


def linear_inverse(step,args):
    y,slope,intercept=D(args['y']),D(args['slope']),D(args['intercept'])
    if slope==0: raise ValueError('Zero slope')
    value=(y-intercept)/slope
    return {'value':str(value)},record(step,'x=(y-intercept)/slope',
            f'({y}-{intercept})/{slope}',args,{},value,'ug/mL')


def qc_range(step,args):
    x,lo,hi=D(args['x']),D(args['low']),D(args['high'])
    flag=lo<=x<=hi
    warnings=[] if flag else ['Value is outside standard range']
    return {'in_range':flag},record(step,'low <= value <= high',
            f'{lo} <= {x} <= {hi}',args,{},str(flag).lower(),None,warnings)


def multiply(step,args):
    a,b=D(args['a']),D(args['b'])
    value=a*b
    return {'value':str(value)},record(step,'a*b',f'{a}*{b}',args,{},value,'ug/mL')


def unit_convert(step,args):
    # Do NOT trust an AI-generated factor without matching a registered unit pair.
    allowed_factors={('ug/mL','mg/mL'):D('0.001'), ('mg/mL','ug/mL'):D('1000')}
    pair=(step['params']['from'],step['params']['to'])
    if pair not in allowed_factors:
        raise ValueError('Unsupported unit conversion: '+str(pair))
    a=D(args['value']); factor=allowed_factors[pair]
    if D(step['params']['factor']) != factor:
        raise ValueError('AI-supplied factor conflicts with validated unit registry')
    out=a*factor
    return {'value':str(out)},record(step,'value*unit_conversion_factor',
           f'{a}*{factor}',args,{'from':pair[0],'to':pair[1],'factor':factor},
           out,pair[1])

REGISTRY={
 'bca.blank_adjust@1':bca_blank,
 'math.subtract@1':subtract,
 'stats.linear_regression@1':linear_fit,
 'math.linear_inverse@1':linear_inverse,
 'data.qc_range@1':qc_range,
 'math.multiply@1':multiply,
 'math.unit_convert@1':unit_convert,
}


def validate_plan(pack, allow_draft=False):
    if pack.get('kind')!='calculation': raise ValueError('Not a calculation pack')
    if not allow_draft and (pack['status']!='approved' or not pack['review']['approved_by_user']):
        raise PermissionError('Pack must be approved for live experiments')
    ids=set()
    for step in pack['pipeline']:
        if step['step_id'] in ids: raise ValueError('Duplicate step_id')
        ids.add(step['step_id'])
        if step['op'] not in REGISTRY:
            raise ValueError('unsupported_operations: '+step['op'])
    return True


def execute(pack, input_values, allow_draft=False):
    validate_plan(pack,allow_draft=allow_draft)
    ctx={'inputs':input_values,'steps':{}}
    steps=[]
    for item in pack['pipeline']:
        args={k:ref_value(v,ctx) for k,v in item['inputs'].items()}
        out,trace=REGISTRY[item['op']](item,args)
        ctx['steps'][item['step_id']]=out
        trace['seq']=len(steps)+1
        steps.append(stable(trace))
    final=[]
    for item in pack['outputs']:
        final.append({'key':item['key'],'value':str(ref_value(item['from_ref'],ctx)),'unit':item.get('unit')})
    warnings=[]
    for gate in pack['quality_gates']:
        good=ref_value(gate['expression_ref'],ctx)
        if not good:
            if gate['severity']=='block': raise ValueError('Quality gate blocked: '+gate['message'])
            warnings.append(gate['message'])
    tool_sha=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return stable({'schema_version':'2.0','trace_id':'example-trace-001','calculation_id':'example-calculation-001',
      'pack_ref':pack['pack_id']+'@'+pack['version'],
      'engine':{'executor_id':'trusted-stdlib-demo','python_version':sys.version.split()[0],
                'primitive_versions':{k:'1' for k in sorted({s['op'] for s in pack['pipeline']})},
                'platform':platform.system()},
      'inputs':[{'key':k,'value':json.dumps(v,ensure_ascii=False) if isinstance(v,list) else str(v), 'unit':None} for k,v in input_values.items()],
      'steps':steps,'outputs':final,'source_assets':[],'warnings':warnings+[f'demo-engine-sha256={tool_sha}'],
      'user_confirmed':False})

if __name__=='__main__':
    root=Path(__file__).resolve().parents[1]
    pack=json.loads((root/'examples/bca/pipeline.json').read_text(encoding='utf8'))
    sample=pack['tests'][0]
    trace=execute(pack,sample['inputs'],allow_draft=True)
    print(json.dumps(trace,ensure_ascii=False,indent=2))
