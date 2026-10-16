"""Trusted, declarative calculation runtime for Lab Workspace.

This package executes only the versioned primitives registered in
``primitives.py``. A calculation pack is data, never Python source.
"""

from .pipeline import (
    CalculationError,
    ExecutionControl,
    GoldenTestReport,
    PackValidationReport,
    execute_approved_pack,
    run_golden_tests,
    validate_pack,
)
from .primitives import PRIMITIVES, PrimitiveDefinition
from .roi import (
    OriginalPixelPlane,
    OriginalRoiPixelSamples,
    Roi,
    RoiApproval,
    quantify_original_roi,
    quantify_original_roi_samples,
)

__all__ = [
    "CalculationError",
    "ExecutionControl",
    "GoldenTestReport",
    "OriginalPixelPlane",
    "OriginalRoiPixelSamples",
    "PackValidationReport",
    "PRIMITIVES",
    "PrimitiveDefinition",
    "Roi",
    "RoiApproval",
    "execute_approved_pack",
    "quantify_original_roi",
    "quantify_original_roi_samples",
    "run_golden_tests",
    "validate_pack",
]
