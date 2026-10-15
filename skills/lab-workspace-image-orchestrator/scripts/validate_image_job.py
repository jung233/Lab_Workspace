#!/usr/bin/env python3
"""Check tool plan schema, scientific image policy and consent."""
import json
from pathlib import Path
import sys
SCHEMA=Path(__file__).resolve().parent.parent/'references/image-tool-plan-v2.schema.json'
ALLOWED={'inspect_metadata','create_model_preview','suggest_rois','render_overlay',
         'crop_derived','compute_roi_pixels','save_derived_asset','export_image_report'}

def validate(obj):
    import jsonschema
    jsonschema.validate(obj,json.loads(SCHEMA.read_text(encoding='utf8')))
    for action in obj['tools']:
        tool=action['tool']
        if tool not in ALLOWED:raise ValueError('not approved tool')
        if tool in ('create_model_preview','suggest_rois') and not obj['user_consented_to_upload']:
            raise ValueError('External AI image use requires explicit consent')
        if tool in ('suggest_rois','compute_roi_pixels') and not action['requires_user_approval']:
            raise ValueError('ROI proposals/quantitation need user review')
        if tool=='compute_roi_pixels' and obj['mode']!='scientific_quantification':
            raise ValueError('quantitation tool used in wrong mode')
    return len(obj['tools'])

if __name__=='__main__':
    print('VALID image plan',validate(json.loads(Path(sys.argv[1]).read_text(encoding='utf8'))),'tools')
