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
    '8dee4f6b6146e384a218d77edb3f23aa5832d184d99d06282e914ac40c41021f';

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
    '4a55638243cb7255b5a481e222f1691346d7b85dc592714df9ce142088ac68a2';

/// The following runtime provenance hashes are independent of the primitive
/// bundle and identify trusted Python entry/native/build source bundles.
const pythonDesktopEntrySourceSha256 =
    '937dad89121e45beeb8295f23466d3c528a635dccd03fcb07a4fd5381aab6da3';
const pythonMobileEntrySourceSha256 =
    '109762a4ec578b9b5e3459aea0e21b867d9a5a950046627326da0f5d92e6744b';
const androidPythonRunnerSourceSha256 =
    '2bb2cd7151a8de1bc7e5e2c21c6a2185d0fc0628286d99427cf0c005fd23bf5f';
const iosPythonRunnerSourceSha256 =
    '2526de119016b6c3bbaf92180911bf1355e0da21c4ae70e468f844235a589444';
const androidPythonPreparationSourceSha256 =
    '7c310469e9c40886151e6a86aadbf0a7e25b63a25074fe07cd876084fea36ff6';
const iosPythonPreparationSourceSha256 =
    '471052b60265ca398aa8bd30bf4a3afbdc53064b6b1f3a5b669a7588516f5aa0';

const calculationSourceManifestVersion = 'lab-workspace-calculation-sources-v1';
