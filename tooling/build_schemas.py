#!/usr/bin/env python3
"""Generate the versioned contract schemas. Run only when changing the contracts."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1] / 'contracts'
ROOT.mkdir(exist_ok=True)
OBJ = lambda props, req=None: {'type': 'object', 'additionalProperties': False, 'properties': props, 'required': list(props) if req is None else req}
STR = {'type': 'string'}
NULLSTR = {'type': ['string','null']}
NONEMPTY = {'type': 'string', 'minLength': 1}
SHA = {'type': 'string', 'pattern': '^[a-f0-9]{64}$'}
REF = {'type': 'string', 'minLength': 1}
ARR = lambda item: {'type': 'array', 'items':item}
INT = {'type':'integer'}
DEC = {'type':['string','number','integer']}

def write(name, properties, defs=None):
 s = {'$schema':'https://json-schema.org/draft/2020-12/schema', '$id': f'https://labworkspace.local/contracts/{name}',
      'title':name, **OBJ(properties)}
 if defs: s['$defs']=defs
 (ROOT/name).write_text(json.dumps(s,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

src=OBJ({'asset_id':REF,'sha256':SHA,'page':{'type':['integer','null'],'minimum':1},'quote':NULLSTR,'origin':{'enum':['sop','user','history','ai_suggestion','unknown']}},['asset_id','sha256','origin'])
var=OBJ({'key':REF,'kind':{'enum':['decimal','integer','text','date','choice','sample_ref','asset_ref','boolean']},'unit':NULLSTR,'required':{'type':'boolean'},'default':{}},['key','kind','required'])
dur=OBJ({'expected_seconds':{'type':['integer','null'],'minimum':0},'source':{'enum':['sop','user','historical','ai_estimate','unknown']},'source_quote':NULLSTR},['expected_seconds','source'])
step=OBJ({'step_id':REF,'kind':{'enum':['action','wait','measure','calculate','image','record','decision','repeat','sample','review']},
    'title':NONEMPTY,'instructions':STR,'depends_on':ARR(REF),'duration':dur,
    'captures':ARR(OBJ({'key':REF,'kind':STR,'unit':NULLSTR,'required':{'type':'boolean'}},['key','kind','required'])),
    'tool_pack_ref':NULLSTR,'human_gate':{'type':'boolean'},'evidence':{'anyOf':[src,{'type':'null'}]},
    'repeat_max':{'type':['integer','null'],'minimum':1,'maximum':1000},'params':{'type':'object'},'output_bindings':{'type':'object'}},
    ['step_id','kind','title','depends_on','duration','human_gate'])
write('protocol-v2.schema.json',{'schema_version':{'const':'2.0'},'protocol_id':REF,'version':NONEMPTY,
      'title':NONEMPTY,'status':{'enum':['draft','approved','archived']},'sources':ARR(src),'variables':ARR(var),'steps':{'type':'array','minItems':1,'items':step},
      'review':OBJ({'approved_by_user':{'type':'boolean'},'warnings':ARR(STR)},['approved_by_user','warnings'])})

infield=OBJ({'key':REF,'kind':{'enum':['decimal','integer','text','table','asset_ref','sample_ref','boolean']},'unit':NULLSTR,'required':{'type':'boolean'}},['key','kind','required'])
op=OBJ({'step_id':REF,'op':{'type':'string','pattern':'^[a-z][a-z0-9_.]*@[0-9]+$'},'inputs':{'type':'object','additionalProperties':{'type':['string','number','boolean']}},'params':{'type':'object'}},['step_id','op','inputs','params'])
outfield=OBJ({'key':REF,'from_ref':REF,'unit':NULLSTR},['key','from_ref','unit'])
gate=OBJ({'id':REF,'expression_ref':REF,'severity':{'enum':['warn','block']},'message':STR},['id','expression_ref','severity','message'])
case=OBJ({'name':NONEMPTY,'inputs':{'type':'object'},'expected':{'type':'object'},'tolerance':{'type':'object'}},['name','inputs','expected'])
write('calculation-pack-v2.schema.json',{
 'schema_version':{'const':'2.0'},'pack_id':REF,'version':NONEMPTY,'kind':{'const':'calculation'},
 'status':{'enum':['draft','approved','disabled']},'title':NONEMPTY,
 'inputs':ARR(infield),'pipeline':{'type':'array','minItems':1,'items':op},'outputs':{'type':'array','minItems':1,'items':outfield},
 'quality_gates':ARR(gate),'tests':{'type':'array','minItems':1,'items':case},
 'review':OBJ({'approved_by_user':{'type':'boolean'},'warnings':ARR(STR)},['approved_by_user','warnings'])})

file=OBJ({'path':NONEMPTY,'sha256':SHA},['path','sha256'])
write('pack-manifest-v2.schema.json',{'schema_version':{'const':'2.0'},'pack_id':REF,'version':NONEMPTY,
 'kind':{'enum':['calculation','protocol','bundle']},'title':NONEMPTY,'requires_engine':STR,
 'files':{'type':'array','minItems':1,'items':file},'permission_level':{'enum':['declarative_only','trusted_builtin','external_python']},
 'required_primitives':ARR(STR),'signed_by':NULLSTR,'author':STR})

numv=OBJ({'key':REF,'value':DEC,'unit':NULLSTR,'source_ref':NULLSTR},['key','value','unit'])
operation=OBJ({'seq':{'type':'integer','minimum':1},'op':STR,'expression':STR,'substitution':STR,
 'inputs':{'type':'object'},'intermediates':{'type':'object'},'result':numv,'warnings':ARR(STR)},
 ['seq','op','expression','substitution','inputs','intermediates','result','warnings'])
write('calculation-trace-v2.schema.json',{'schema_version':{'const':'2.0'},'trace_id':REF,'calculation_id':REF,
 'pack_ref':STR,'engine':OBJ({'executor_id':STR,'python_version':STR,'primitive_versions':{'type':'object','additionalProperties':STR},'platform':STR},['executor_id','python_version','primitive_versions','platform']),
 'inputs':ARR(numv),'steps':{'type':'array','minItems':1,'items':operation},'outputs':ARR(numv),
 'source_assets':ARR(OBJ({'asset_id':REF,'sha256':SHA},['asset_id','sha256'])),'warnings':ARR(STR),
 'user_confirmed':{'type':'boolean'}})

fullcheck=OBJ({'threshold_bytes':{'type':'integer','minimum':0},'on_import':{'const':'full_sha256'},
 'small_access':{'const':'full_sha256_each_logical_open'},'large_access':{'enum':['fast_metadata','full_sha256_each_open']},
 'last_full_verified_at':NULLSTR,'last_fast_check_at':NULLSTR,'status':{'enum':['verified','quick_checked','overdue','mismatch','missing','pending']}},
 ['threshold_bytes','on_import','small_access','large_access','status'])
write('asset-metadata-v2.schema.json',{'schema_version':{'const':'2.0'},'asset_id':REF,'blob_sha256':SHA,
 'bytes':{'type':'integer','minimum':0},'display_name':NONEMPTY,'kind':{'enum':['raw','derived','report','thumbnail','export']},
 'parent_asset_id':NULLSTR,'integrity':fullcheck,'deleted_at':NULLSTR})

write('sync-event-v2.schema.json',{'schema_version':{'const':'2.0'},'vault_id':REF,'device_id':REF,
 'seq':{'type':'integer','minimum':1},'lamport':{'type':'integer','minimum':1},'event_id':REF,
 'entity_kind':NONEMPTY,'entity_id':REF,'base_revision':{'type':['integer','null'],'minimum':1},
 'action':{'enum':['create','patch','append','tombstone','resolve']},'payload':{'type':'object'},'sha_refs':ARR(SHA),
 'created_at_utc':{'type':'string','format':'date-time'}})

write('remote-storage-policy-v2.schema.json',{'schema_version':{'const':'2.0'},'target_id':REF,
 'provider':{'enum':['s3','onedrive']},'encryption':{'enum':['none','encrypt_metadata','encrypt_all','custom']},
 'encrypt_metadata':{'type':'boolean'},'encrypt_small_files':{'type':'boolean'},'encrypt_large_files':{'type':'boolean'},
 'key_id':NULLSTR,'large_file_threshold_bytes':{'type':'integer','minimum':0},'large_upload':{'enum':['manual','wifi_only','automatic','off']},
 'backup':{'type':'boolean'},'sync':{'type':'boolean'}})
# Cross-field semantic constraints to prevent a misleading encryption setting.
_remote=ROOT/'remote-storage-policy-v2.schema.json'
_remote_schema=json.loads(_remote.read_text(encoding='utf8'))
_remote_schema['allOf']=[
 {'if':{'properties':{'encryption':{'const':'none'}}},
  'then':{'properties':{'encrypt_metadata':{'const':False},'encrypt_small_files':{'const':False},'encrypt_large_files':{'const':False},'key_id':{'type':'null'}}}},
 {'if':{'properties':{'encryption':{'const':'encrypt_all'}}},
  'then':{'properties':{'encrypt_metadata':{'const':True},'encrypt_small_files':{'const':True},'encrypt_large_files':{'const':True},'key_id':{'type':'string','minLength':1}}}},
 {'if':{'properties':{'encryption':{'const':'encrypt_metadata'}}},
  'then':{'properties':{'encrypt_metadata':{'const':True},'key_id':{'type':'string','minLength':1}}}},
 {'if':{'anyOf':[{'properties':{'encrypt_metadata':{'const':True}}},{'properties':{'encrypt_small_files':{'const':True}}},{'properties':{'encrypt_large_files':{'const':True}}}]},
  'then':{'properties':{'key_id':{'type':'string','minLength':1}}}}
]
_remote.write_text(json.dumps(_remote_schema,ensure_ascii=False,indent=2)+'\n',encoding='utf8')

roi=OBJ({'x':{'type':'integer','minimum':0},'y':{'type':'integer','minimum':0},'width':{'type':'integer','minimum':1},'height':{'type':'integer','minimum':1}},['x','y','width','height'])
tool=OBJ({'tool':{'enum':['inspect_metadata','create_model_preview','suggest_rois','render_overlay','crop_derived','compute_roi_pixels','save_derived_asset','export_image_report']},
 'params':{'type':'object'},'requires_user_approval':{'type':'boolean'},'roi':{'anyOf':[roi,{'type':'null'}]}},['tool','params','requires_user_approval'])
write('image-tool-plan-v2.schema.json',{'schema_version':{'const':'2.0'},'job_id':REF,'source_asset_id':REF,'source_sha256':SHA,
 'mode':{'enum':['image_documentation','report_extraction','scientific_quantification','presentation_edit']},
 'user_consented_to_upload':{'type':'boolean'},'tools':ARR(tool),'never_overwrite_original':{'const':True},
 'use_generated_pixels_for_quantitation':{'const':False}})


formfield=OBJ({'key':REF,'label':NONEMPTY,'widget':{'enum':['text','decimal','integer','choice','file','table','sample','checkbox']},
    'unit':NULLSTR,'required':{'type':'boolean'}},['key','label','widget','required'])
formout=OBJ({'key':REF,'label':NONEMPTY,'unit':NULLSTR,'show_trace_button':{'const':True}},['key','label','show_trace_button'])
write('forms-v2.schema.json',{'schema_version':{'const':'2.0'},'title':NONEMPTY,
 'fields':{'type':'array','minItems':1,'items':formfield},
 'outputs':{'type':'array','minItems':1,'items':formout},'warning':STR})

if __name__ == '__main__':
 print('Generated', len(list(ROOT.glob('*.json'))),'contract schemas')
