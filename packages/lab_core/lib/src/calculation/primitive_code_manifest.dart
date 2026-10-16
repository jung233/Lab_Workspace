/// Source-bundle digests for the trusted Dart calculation engine.
///
/// Each digest is SHA-256 over UTF-8 lines of
/// `<repository-relative-path>\t<sha256(file-bytes)>\n`, in the order shown.
/// This manifest is excluded from each bundle it describes.
/// Dart primitive paths:
/// `packages/lab_core/lib/src/calculation/calculation_engine.dart`,
/// `packages/lab_core/lib/src/calculation/decimal_support.dart`,
/// `packages/lab_core/lib/src/calculation/primitive_registry.dart`,
/// `packages/lab_core/lib/src/calculation/unit_registry.dart`,
/// `packages/lab_core/lib/src/domain/json_value.dart`.
const dartCalculationPrimitiveCodeSha256 =
    'db0dff600ebdc58049c38eec84a87368dc12dad99c032fae23591a9f1d9ffcae';

/// Original-image ROI arithmetic source bundle, independently pinned from
/// generic Pack primitives.
const imageRoiPrimitiveCodeSha256 =
    'd90d920537516c05c2b96625d6a56bd20498afec33cdc22cc4edb546cdd95d54';

/// Python Pack primitive bundle (same digest on desktop and mobile Python).
/// Ordered repository-relative files are
/// `python/lab_workspace_calculation/canonical.py`,
/// `python/lab_workspace_calculation/decimal_support.py`,
/// `python/lab_workspace_calculation/pipeline.py`,
/// `python/lab_workspace_calculation/primitives.py`, and
/// `python/lab_workspace_calculation/units.py`.
const pythonCalculationPrimitiveCodeSha256 =
    '83da4329010ea424885039a8873f7a6fc30126e76cffb30036f9a3aee554a9d3';

/// Digest for the Dart calculation runtime wrapper source, distinct from the
/// mathematical primitive bundle above. Ordered source files:
/// `packages/lab_core/lib/src/calculation/calculation_executor.dart`,
/// `packages/lab_core/lib/src/calculation/calculation_service.dart`.
const dartCalculationRuntimeSourceSha256 =
    'cb1d092454293d6b2de88f20afebae8cd424d30c86b4555c773e26ae0eedf0a7';

/// The following runtime provenance hashes are independent of the primitive
/// bundle and identify trusted Python entry/native/build source bundles.
const pythonDesktopEntrySourceSha256 =
    '937dad89121e45beeb8295f23466d3c528a635dccd03fcb07a4fd5381aab6da3';
const pythonMobileEntrySourceSha256 =
    '3da7b53970c439a147e01cc9dcff68fa40632760849705cfa48ea57ca18f846c';
const androidPythonRunnerSourceSha256 =
    '4fae4fcb9f3054f89b880e2a14839d67b9cbaadb4ce5d4388b18b305b8534cd3';
const iosPythonRunnerSourceSha256 =
    '2526de119016b6c3bbaf92180911bf1355e0da21c4ae70e468f844235a589444';
const androidPythonPreparationSourceSha256 =
    'b64edb82e7b8e3b3ea6f05e60fd43d58e02178cfa05f5f30ddef4b10d0d7c2c2';
const iosPythonPreparationSourceSha256 =
    '9a6773f768d3e5518fd371db190c1e13ed519039047b5386348ff850d7c7dc94';

const calculationSourceManifestVersion = 'lab-workspace-calculation-sources-v1';
