"""Pinned source-bundle hashes for trusted calculation primitives.

Both digests are SHA-256 over UTF-8 lines of
``<repository-relative-path>\t<sha256(file-bytes)>\n``. The image ROI order is
``python/lab_workspace_calculation/canonical.py``,
``python/lab_workspace_calculation/decimal_support.py``,
``python/lab_workspace_calculation/roi.py``, and
``python/lab_workspace_calculation/units.py``. The Pack order is
``python/lab_workspace_calculation/canonical.py``,
``python/lab_workspace_calculation/decimal_support.py``,
``python/lab_workspace_calculation/pipeline.py``,
``python/lab_workspace_calculation/primitives.py``, and
``python/lab_workspace_calculation/units.py``. This manifest module is
excluded from both bundles to avoid a self-referential digest. The Pack
primitive bundle is separate from image ROI arithmetic.
"""

IMAGE_ROI_PRIMITIVE_CODE_SHA256 = (
    "d90d920537516c05c2b96625d6a56bd20498afec33cdc22cc4edb546cdd95d54"
)

PYTHON_PACK_PRIMITIVE_CODE_SHA256 = (
    "83da4329010ea424885039a8873f7a6fc30126e76cffb30036f9a3aee554a9d3"
)
