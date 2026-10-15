"""Tests for the engineering reference kit, not the not-yet-built Flutter app."""
from __future__ import annotations
import copy
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from decimal import Decimal

import jsonschema
ROOT=Path(__file__).resolve().parents[1]

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    import sys
    sys.modules[name]=module
    spec.loader.exec_module(module)
    return module

runtime=load('lw_runtime',ROOT/'python/pack_runtime_demo.py')
integrity=load('lw_integrity',ROOT/'python/integrity_policy_demo.py')
validator=load('lw_validator',ROOT/'tooling/validate_contracts.py')
manifest_tool=load('lw_manifest',ROOT/'tooling/manifest_tool.py')
proto_skill=load('lw_protocol_skill',ROOT/'skills/lab-workspace-protocol-author/scripts/validate_protocol.py')
workflow_skill=load('lw_workflow_skill',ROOT/'skills/lab-workspace-workflow-author/scripts/validate_workflow.py')
image_skill=load('lw_image_skill',ROOT/'skills/lab-workspace-image-orchestrator/scripts/validate_image_job.py')

def j(path):return json.loads((ROOT/path).read_text(encoding='utf8'))

class ReferenceTest(unittest.TestCase):
    def test_nine_contract_schemas(self):
        self.assertEqual(validator.validate_examples(),9)

    def test_mixed_remote_encryption_policy(self):
        jsonschema.validate(j('examples/storage/cloud-policy-mixed.json'),j('contracts/remote-storage-policy-v2.schema.json'))
        mixed=j('examples/storage/cloud-policy-mixed.json')
        self.assertTrue(mixed['encrypt_metadata'])
        self.assertFalse(mixed['encrypt_large_files'])

    def test_pack_manifest_checks_schema_and_files(self):
        base=ROOT/'examples/installed_packs/bca-standard-curve/1.0.0'
        manifest=j('examples/installed_packs/bca-standard-curve/1.0.0/manifest.json')
        jsonschema.validate(manifest,j('contracts/pack-manifest-v2.schema.json'))
        manifest_tool.validate_pack_files(base)

    def test_pack_corrupted_file_blocked(self):
        base=ROOT/'examples/installed_packs/bca-standard-curve/1.0.0'
        with tempfile.TemporaryDirectory() as tmp:
            from shutil import copytree
            dest=Path(tmp)/'pack'
            copytree(base,dest)
            with (dest/'forms.json').open('a',encoding='utf8') as f:f.write('tampered')
            with self.assertRaisesRegex(ValueError,'File hash mismatch'):
                manifest_tool.validate_pack_files(dest)

    def test_bca_python_declarative_pack(self):
        pack=j('examples/bca/pipeline.json')
        self.assertTrue(validator.validate_pack(pack,runtime.REGISTRY))
        result=runtime.execute(pack,pack['tests'][0]['inputs'],allow_draft=True)
        self.assertEqual(Decimal(result['outputs'][0]['value']),Decimal('1.5'))
        self.assertEqual(len(result['steps']),7)
        self.assertIn('xbar',result['steps'][2]['intermediates'])
        jsonschema.validate(result,j('contracts/calculation-trace-v2.schema.json'))

    def test_unknown_operation_does_not_execute(self):
        pack=j('examples/bca/pipeline.json')
        pack['pipeline'][0]['op']='model.generated_unsafe_code@1'
        with self.assertRaisesRegex(ValueError,'unsupported_operations'):
            runtime.execute(pack,pack['tests'][0]['inputs'],allow_draft=True)

    def test_unapproved_pack_cannot_be_used_in_live_run(self):
        pack=j('examples/bca/pipeline.json')
        with self.assertRaises(PermissionError):
            runtime.execute(pack,pack['tests'][0]['inputs'])

    def test_protocol_dag_and_time_provenance(self):
        pack=j('examples/protocol/bca-to-wb.json')
        self.assertEqual(proto_skill.validate(pack),5)
        pack['steps'][0]['depends_on']=['record_wb_image']
        with self.assertRaisesRegex(ValueError,'cycle'):
            proto_skill.validate(pack)

    def test_sop_duration_must_have_source_quote(self):
        pack=j('examples/protocol/bca-to-wb.json')
        pack['steps'][0]['duration']={'source':'sop','expected_seconds':60}
        with self.assertRaisesRegex(ValueError,'source quote'):
            proto_skill.validate(pack)

    def test_workflow_no_forward_reference(self):
        pack=j('examples/bca/pipeline.json')
        self.assertEqual(workflow_skill.validate(pack),7)
        pack['pipeline'][0]['inputs']['standards']='$steps.fit.slope'
        with self.assertRaisesRegex(ValueError,'forward'):
            workflow_skill.validate(pack)

    def test_image_roi_review_and_upload_consent(self):
        job=j('examples/storage/image-review-plan.json')
        self.assertEqual(image_skill.validate(job),3)
        job['user_consented_to_upload']=False
        with self.assertRaisesRegex(ValueError,'consent'):
            image_skill.validate(job)

    def test_sqlite_ddl_and_asset_blob_immutability(self):
        c=sqlite3.connect(':memory:');c.executescript((ROOT/'db/001_init.sql').read_text())
        c.execute("INSERT INTO blob_objects(sha256,byte_size,relative_path,state,imported_at_utc) VALUES (?,?,?,?,?)",('a'*64,3,'objects/aa','committed','now'))
        c.execute("INSERT INTO assets(asset_id,blob_sha256,display_name,kind,created_at_utc) VALUES (?,?,?,?,?)",('asset','a'*64,'raw','raw','now'))
        with self.assertRaises(sqlite3.IntegrityError):
            c.execute("UPDATE blob_objects SET byte_size=4 WHERE sha256=?",('a'*64,))
        with self.assertRaises(sqlite3.IntegrityError):
            c.execute("UPDATE assets SET blob_sha256=? WHERE asset_id='asset'",('b'*64,))

    def test_integrity_small_every_read_and_large_fast_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'a.bin';p.write_bytes(b'ABCDE')
            baseline=integrity.ingest_baseline(p)
            small=integrity.validate_logical_open(p,baseline,threshold=5)
            self.assertEqual(small['mode'],'full_sha256')
            self.assertEqual(small['status'],'verified')
            big=integrity.validate_logical_open(p,baseline,threshold=4)
            self.assertEqual(big['mode'],'metadata_quick')
            self.assertIsNone(big['sha256'])
            orig_mtime=p.stat().st_mtime_ns
            p.write_bytes(b'VWXYZ')
            os.utime(p,ns=(orig_mtime,orig_mtime))
            self.assertEqual(integrity.validate_logical_open(p,baseline,threshold=5)['status'],'mismatch')
            # Important risk: same-size/mtime corruption can evade large-file fast metadata checking.
            self.assertEqual(integrity.validate_logical_open(p,baseline,threshold=4)['status'],'quick_checked')

if __name__=='__main__':unittest.main(verbosity=2)

class HardeningTests(unittest.TestCase):
    def test_unit_factor_cannot_be_forged_by_ai(self):
        pack=j('examples/bca/pipeline.json')
        pack['pipeline'][-1]['params']['factor']='42'
        with self.assertRaisesRegex(ValueError,'validated unit registry'):
            runtime.execute(pack,pack['tests'][0]['inputs'],allow_draft=True)

    def test_unencrypted_policy_cannot_fake_encryption(self):
        cfg=j('examples/storage/cloud-policy-unencrypted.json')
        cfg['encrypt_large_files']=True
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(cfg,j('contracts/remote-storage-policy-v2.schema.json'))

    def test_out_of_range_bca_warns(self):
        pack=j('examples/bca/pipeline.json')
        sample=copy.deepcopy(pack['tests'][0]['inputs'])
        sample['sample_absorbance']='1.1'
        trace=runtime.execute(pack,sample,allow_draft=True)
        self.assertTrue(any('范围' in w for w in trace['warnings']))

class DynamicFormsTests(unittest.TestCase):
    def test_form_matches_pack_and_enforces_trace_button(self):
        forms=j('examples/installed_packs/bca-standard-curve/1.0.0/forms.json')
        pack=j('examples/bca/pipeline.json')
        self.assertTrue(validator.validate_forms(forms,pack))
        forms['outputs'][0]['show_trace_button']=False
        with self.assertRaisesRegex(ValueError,'show_trace_button'):
            validator.validate_forms(forms,pack)
