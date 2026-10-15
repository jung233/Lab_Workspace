---
name: lab-workspace-image-orchestrator
description: Coordinate multimodal AI review and allowlisted image tools for Lab Workspace biomedical images, including BCA report photos, western blot bands, immunofluorescence and microscope imagery. Use when extracting report text, planning user-approved ROIs, cropping or annotating derived images, running deterministic original-pixel intensity calculations, or preparing transparent scientific figure reports; never perform local automated visual recognition/segmentation.
---

# Lab Workspace Image Orchestrator

Multimodal AI **understands, proposes and chooses tools**. Trusted app image tools **perform exact geometry, visualization and approved pixel arithmetic**. AI output is never itself proof of quantitative measurement. Preserve all raw image bytes and SHA-256.

## Inputs and consent

Require source Asset ID/SHA-256, image purpose, user-confirmed upload consent, sample/lane mapping when relevant, and the requested mode: `image_documentation`, `report_extraction`, `scientific_quantification`, or `presentation_edit`. If offline/no vision model, do not fabricate a suggestion; queue the job or let the user manually mark ROIs.

## Workflow

1. Verify source exists; apply the asset's small-vs-large integrity policy; report whether validation is full SHA or only metadata quick-check.
2. Inspect metadata; if model input is authorized, request a derivative preview that preserves pixel coordinate transforms, orientation and dimensions.
3. Ask the configured vision model to propose specific operations from `references/image-tool-catalog.json`; treat all suggestions as untrusted and validate tool arguments.
4. For extracted BCA report numerics, show original text/position and require field-by-field confirmation. Never infer absolute protein concentration from mere color of plate photograph without instrument measurements and calibration.
5. For WB/IF ROI proposals, show overlays and the original image, collect human approval of exact pixel geometry, channel and background method.
6. Call deterministic `compute_roi_pixels` only on original unchanged pixels and approved ROI. Emit CalculationTrace containing input SHA, ROI, arithmetic steps, intermediate values, versions and warnings.
7. Save every crop, annotation, illustrative edit or report as a **new derived Asset** with its own SHA and parent source; do not overwrite originals or silently relabel artificial pixels as microscopy signal.
8. Present results with `[展示原始计算]`, `[查看原始图像]`, model/tool invocation log, version, caveats and user confirmation status.

## Hard prohibitions

- No local automatic CV detection, classifier inference or segmentation built into Lab Workspace. Cropping, overlays, raw pixel arithmetic and metadata are not model recognition and are allowed as explicit user-approved tools.
- No generative inpainting, re-synthesized WB bands, intensity edits, background removal or fictional fluorescence as measurement input.
- No arbitrary filesystem paths, deletion, external URL fetch, shell, secret access or unattended model upload.
- If the user wants only beautified graphics, mark results `presentation_edit` and forbid quantitative reuse.
- Image Skill instructions do not themselves provide executable image tools. The App Tool Registry must expose actual, authorized implementations.

Read `references/image-tool-plan-v2.schema.json`, `references/example-image-review.json`, and `references/quantitative-image-checklist.md`. Validate plans with `scripts/validate_image_job.py` when execution is available.
