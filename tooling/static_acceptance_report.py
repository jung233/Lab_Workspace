"""Report source-level evidence for V2.0 safety gates.

This is a static inventory aid, not a test runner. It does not import or execute
application code and makes no claim about runtime or platform behavior.
"""
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    path = ROOT / relative
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def report() -> int:
    checks: tuple[tuple[str, str, tuple[str, ...]], ...] = (
        (
            "Separate AI API adapters",
            "packages/lab_core/lib/src/ai/provider_adapters.dart",
            ("class ResponsesAdapter", "class ChatCompletionsAdapter"),
        ),
        (
            "AI requests avoid server-side response storage",
            "packages/lab_core/lib/src/ai/provider_adapters.dart",
            ("'store': false",),
        ),
        (
            "Upload requests enforce receipt coverage",
            "packages/lab_core/lib/src/ai/ai_provider_service.dart",
            ("AI_UPLOAD_CONSENT_REQUIRED", "AI_UPLOAD_CONSENT_INVALID", "stored.dataClass"),
        ),
        (
            "AI tools require registration and bounded rounds",
            "packages/lab_core/lib/src/ai/ai_provider_service.dart",
            ("AI_TOOL_UNSUPPORTED", "AI_TOOL_ROUND_LIMIT", "_validateArguments"),
        ),
        (
            "AI tool approval binds exact parameters and Assets",
            "packages/lab_core/lib/src/ai/sqlite_ai_repositories.dart",
            ("ai.tool.execute", "parameters", "request.assetIds.toList()..sort()"),
        ),
        (
            "Pack generation remains draft until approval flow",
            "packages/lab_core/lib/src/ai/pack_draft_service.dart",
            ("_forceDraft", "approveAndInstall", "if (!golden.passed)"),
        ),
        (
            "Image quantitative path excludes generated pixels",
            "packages/lab_core/lib/src/image/image_tool_registry.dart",
            ("request.generatedPixels", "request.roi == null", "ImageJobMode.scientificQuantification"),
        ),
        (
            "Image quantification requires reviewed original and trace",
            "packages/lab_core/lib/src/image/image_analysis_service.dart",
            ("IMAGE_FULL_SHA_REQUIRED", "IMAGE_ROI_REVIEW_REQUIRED", "generated_pixels_used_for_quantitation"),
        ),
        (
            "Image trace binds approved source, primitive derivation, and canonical SHA",
            "packages/lab_core/lib/src/image/image_calculation_trace.dart",
            ("validateRoiTrace", "IMAGE_TRACE_OUTPUT_MAPPING_INVALID", "content_sha256", "verifyPersisted"),
        ),
        (
            "Scientific TIFF decoder preserves unsigned integer pages",
            "apps/lab_workspace/lib/src/ai_image/png_image_platform.dart",
            ("TiffDecoder", "img.Format.uint16", "pageIndex", "IMAGE_TIFF_FORMAT_UNSUPPORTED"),
        ),
        (
            "To Do sync limits writes to primary device and checks ETags",
            "packages/lab_core/lib/src/integrations/microsoft_todo_sync_service.dart",
            ("primary != _currentDeviceId", "ifMatchEtag", "MicrosoftTodoPreconditionFailed"),
        ),
        (
            "To Do re-syncs locally edited task revisions",
            "packages/lab_core/lib/src/integrations/sqlite_microsoft_todo_repository.dart",
            ("t.revision>COALESCE(l.local_revision,0)", "local_revision=excluded.local_revision"),
        ),
        (
            "Provider credentials use opaque references",
            "packages/lab_core/lib/src/ai/sqlite_ai_repositories.dart",
            ("secret_ref", "SecretRef(row['secret_ref'] as String)"),
        ),
    )
    missing = 0
    for label, relative, markers in checks:
        source = read(relative)
        absent = [marker for marker in markers if marker not in source]
        status = "PRESENT" if not absent else "MISSING"
        print(f"[{status}] {label} ({relative})")
        if absent:
            print("  missing source markers: " + ", ".join(absent))
            missing += 1
    print("Static markers are evidence locations only; review code and platform wiring separately.")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(report())
