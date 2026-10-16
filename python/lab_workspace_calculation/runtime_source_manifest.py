"""Pinned source hashes for trusted calculation entry points and native hosts.

Each digest is SHA-256 over UTF-8 lines of
``<workspace-relative-path>\t<sha256(file-bytes)>\n`` in the documented order.
This manifest is excluded from every bundle it describes. These runtime
digests identify the entry/host/build source and are distinct from the
mathematical primitive bundle digest in ``primitive_code_manifest.py``.
"""

from __future__ import annotations

from typing import Any


RUNTIME_SOURCE_MANIFEST_VERSION = "lab-workspace-calculation-sources-v1"

# Entry bundles are rooted at the repository root. The desktop order is
# ``python/lab_workspace_calculation/pipeline.py`` then
# ``python/runner/calculation_rpc.py``. The mobile order is the same pipeline
# then ``python/mobile/calculation_mobile_bridge.py``.
PYTHON_DESKTOP_ENTRY_SOURCE_SHA256 = (
    "937dad89121e45beeb8295f23466d3c528a635dccd03fcb07a4fd5381aab6da3"
)
PYTHON_MOBILE_ENTRY_SOURCE_SHA256 = (
    "109762a4ec578b9b5e3459aea0e21b867d9a5a950046627326da0f5d92e6744b"
)

# Native runner bundles are separate from Python numeric primitives/entry code.
# Android order: ``apps/lab_workspace/android/app/src/main/kotlin/org/labworkspace/app/MainActivity.kt``
# then ``apps/lab_workspace/android/app/src/main/kotlin/org/labworkspace/app/calculation/CalculationPythonRunner.kt``.
# iOS order: ``apps/lab_workspace/ios/Runner/AppDelegate.swift`` then
# ``apps/lab_workspace/ios/Runner/PythonRunner/LabCalculationPythonRunner.h``
# then ``apps/lab_workspace/ios/Runner/PythonRunner/LabCalculationPythonRunner.m``.
ANDROID_NATIVE_RUNNER_SOURCE_SHA256 = (
    "2bb2cd7151a8de1bc7e5e2c21c6a2185d0fc0628286d99427cf0c005fd23bf5f"
)
IOS_NATIVE_RUNNER_SOURCE_SHA256 = (
    "2526de119016b6c3bbaf92180911bf1355e0da21c4ae70e468f844235a589444"
)

# Preparation bundles are tracked independently from runtime binaries.
# Android order: ``apps/lab_workspace/android/app/python_runner.gradle.kts``
# then ``apps/lab_workspace/android/app/build.gradle.kts``. iOS order:
# ``apps/lab_workspace/ios/Runner/PythonRunner/process_python.sh``,
# ``tooling/release/prepare_ios_python.sh``, then
# ``apps/lab_workspace/ios/Runner.xcodeproj/project.pbxproj``.
ANDROID_PREPARATION_SOURCE_SHA256 = (
    "7c310469e9c40886151e6a86aadbf0a7e25b63a25074fe07cd876084fea36ff6"
)
IOS_PREPARATION_SOURCE_SHA256 = (
    "471052b60265ca398aa8bd30bf4a3afbdc53064b6b1f3a5b669a7588516f5aa0"
)


def runtime_source_metadata(executor_id: str, target: str) -> dict[str, Any]:
    """Return a trace-ready, explicit provenance map for the selected runner."""
    if target in {"win32", "cygwin"}:
        target = "windows"
    elif target == "darwin":
        target = "macos"
    result: dict[str, Any] = {
        "runtime_source_manifest_version": RUNTIME_SOURCE_MANIFEST_VERSION,
        "runtime_source_target": target,
    }
    if executor_id == "trusted-python-mobile-v2":
        result.update(
            {
                "runtime_entry_source_sha256": PYTHON_MOBILE_ENTRY_SOURCE_SHA256,
                "native_runner_source_sha256": (
                    ANDROID_NATIVE_RUNNER_SOURCE_SHA256
                    if target == "android"
                    else IOS_NATIVE_RUNNER_SOURCE_SHA256
                    if target == "ios"
                    else "unsupported-target"
                ),
                "runtime_preparation_source_sha256": (
                    ANDROID_PREPARATION_SOURCE_SHA256
                    if target == "android"
                    else IOS_PREPARATION_SOURCE_SHA256
                    if target == "ios"
                    else "unsupported-target"
                ),
            }
        )
    else:
        result["runtime_entry_source_sha256"] = PYTHON_DESKTOP_ENTRY_SOURCE_SHA256
    return result
