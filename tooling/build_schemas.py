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
step_result=OBJ({'key':REF,'value':{'type':['string','number','integer','boolean','null']},
 'unit':NULLSTR,'source_ref':NULLSTR},['key','value','unit'])
operation=OBJ({'seq':{'type':'integer','minimum':1},'op':STR,'expression':STR,'substitution':STR,
 'inputs':{'type':'object'},'intermediates':{'type':'object'},'result':numv,'warnings':ARR(STR),
 'results':ARR(step_result)},
 ['seq','op','expression','substitution','inputs','intermediates','result','warnings'])
source_asset=OBJ({'asset_id':REF,'sha256':SHA,
 'validation_level':{'enum':['verified','quick_checked','unknown']}},['asset_id','sha256'])
execution_context=OBJ({'run_id':NULLSTR,'sample_id':NULLSTR,'step_id':NULLSTR},[])
approval=OBJ({'reference':NONEMPTY,'kind':{'enum':['user_approval','trusted_builtin']}},['reference','kind'])
ai_provenance_item=OBJ({'source':{'enum':['report_extraction','model_suggestion','tool_result']},
 'tool_call_id':NULLSTR,'model_id':NULLSTR,'values':{'type':'object'},'confidence':NULLSTR,
 'user_confirmed':{'type':'boolean'},'confirmation_ref':NULLSTR,'confirmed_at_utc':NULLSTR},
 ['source','user_confirmed'])
precision=OBJ({'decimal_precision':{'type':'integer','minimum':1},'rounding':NONEMPTY,
 'float_inputs_allowed':{'const':False}},['decimal_precision','rounding','float_inputs_allowed'])
execution_environment=OBJ({'runtime':NONEMPTY,'platform':STR,'dependencies':{'type':'object','additionalProperties':STR}},['runtime','platform'])
roi_geometry=OBJ({'x':{'type':'integer','minimum':0},'y':{'type':'integer','minimum':0},
 'width':{'type':'integer','minimum':1},'height':{'type':'integer','minimum':1}},['x','y','width','height'])
quantification_context=OBJ({'source_asset_kind':{'const':'raw'},'source_immutable':{'const':True},
 'generated_pixels_used':{'const':False},'channel_index':{'type':'integer','minimum':0},'channel_name':NONEMPTY,
 'image_width':{'type':'integer','minimum':1},'image_height':{'type':'integer','minimum':1},
 'bit_depth':{'type':'integer','minimum':1,'maximum':32},'signal_roi':roi_geometry,
 'background_roi':{'anyOf':[roi_geometry,{'type':'null'}]},
 'background_method':{'enum':['none','mean_subtract']},'approval_ref':NONEMPTY,
 'approved_at_utc':{'type':'string','format':'date-time'},'reviewer':NONEMPTY},
 ['source_asset_kind','source_immutable','generated_pixels_used','channel_index','channel_name',
  'image_width','image_height','bit_depth','signal_roi','background_roi','background_method',
  'approval_ref','approved_at_utc','reviewer'])
write('calculation-trace-v2.schema.json',{'schema_version':{'const':'2.0'},'trace_id':REF,'calculation_id':REF,
	 'pack_ref':STR,'engine':OBJ({'executor_id':STR,'python_version':STR,'primitive_versions':{'type':'object','additionalProperties':STR},'primitive_code_sha256':{'type':'object','additionalProperties':SHA},'platform':STR},['executor_id','python_version','primitive_versions','platform']),
 'inputs':ARR(numv),'steps':{'type':'array','minItems':1,'items':operation},'outputs':ARR(numv),
 'source_assets':ARR(source_asset),'warnings':ARR(STR),
 'user_confirmed':{'type':'boolean'},'created_at_utc':{'type':'string','format':'date-time'},
 'pack_sha256':SHA,'primitive_build_versions':{'type':'object','additionalProperties':STR},
 'execution_context':execution_context,'approval':approval,'ai_provenance':ARR(ai_provenance_item),
 'recalculation_parent_id':NULLSTR,'precision':precision,'execution_environment':execution_environment,
 'quantification_context':quantification_context})

fullcheck=OBJ({'threshold_bytes':{'type':'integer','minimum':0},'on_import':{'const':'full_sha256'},
 'small_access':{'const':'full_sha256_each_logical_open'},'large_access':{'enum':['fast_metadata','full_sha256_each_open']},
 'last_full_verified_at':NULLSTR,'last_fast_check_at':NULLSTR,'status':{'enum':['verified','quick_checked','overdue','mismatch','missing','pending']}},
 ['threshold_bytes','on_import','small_access','large_access','status'])
write('asset-metadata-v2.schema.json',{'schema_version':{'const':'2.0'},'asset_id':REF,'blob_sha256':SHA,
 'bytes':{'type':'integer','minimum':0},'display_name':NONEMPTY,'kind':{'enum':['raw','derived','report','thumbnail','export']},
 'parent_asset_id':NULLSTR,'integrity':fullcheck,'deleted_at':NULLSTR})

sync_event_fields={'schema_version':{'const':'2.0'},'vault_id':REF,'device_id':REF,
 'seq':{'type':'integer','minimum':1},'lamport':{'type':'integer','minimum':1},'event_id':REF,
 'entity_kind':NONEMPTY,'entity_id':REF,'base_revision':{'type':['integer','null'],'minimum':1},
 'action':{'enum':['create','patch','append','tombstone','resolve']},'payload':{'type':'object'},'sha_refs':ARR(SHA),
 'created_at_utc':{'type':'string','format':'date-time'}}
write('sync-event-v2.schema.json',sync_event_fields)
sync_event_v3_fields={**sync_event_fields,
 'schema_version':{'const':'3.0'},'command_id':REF,
 'event_type':{'enum':[
   'project.created','project.updated','experiment.created','experiment.updated',
   'group.created','group.updated','protocol.draft_saved','protocol.approved',
   'run.created','run.sample_attached','run.closed','schedule.rebuilt',
   'step.added','step.started','step.completed','sample.created',
   'treatment.recorded','treatment.corrected','measurement.recorded',
   'measurement.corrected','measurement.confirmed','measurement.external_reviewed',
   'task.created','task.updated','task.completed','task.deleted',
   'reminder.created','reminder.delivery_updated',
   'setting.updated','calculation.completed','calculation.failed',
   'calculation_pack.installed','AssetImported','AssetTrashed','AssetPurged',
   'AssetRestored','AssetBlobReleased','AssetFolderCreated','AssetAddedToFolder',
   'AssetRemovedFromFolder','AssetPurgeRecoveryRequired','AssetIntegrityFailed',
   'sync.target.created','sync.target.updated','sync.target.removed',
   'BackupSnapshotCreated','BackupSnapshotFailed','BackupSnapshotStateChanged',
   'BackupRestoreVerified'
 ]}}
write('sync-event-v3.schema.json',sync_event_v3_fields)

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
