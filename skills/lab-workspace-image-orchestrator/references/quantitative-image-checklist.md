# Scientific imaging integrity gates

1. Save and log exact original SHA-256 at ingest; for large files after ingest show whether later access used fast metadata checking.
2. Record width, height, channels, bit depth, acquisition/scale parameters if available; if unknown explicitly mark unknown.
3. Store model preview resizing transform so ROIs convert exactly to original pixel coordinates and are bounded by image dimensions.
4. Require visible, reversible human approval of ROI coordinates, background ROI and channel before any quantitative arithmetic.
5. Calculate from untouched original pixels, not from a generator-produced or contrast-altered illustrative image.
6. Save formula, intermediate values, versioned tool identity, source Asset ID + SHA-256, approved ROI, model/tool invocation and reviewer state in CalculationTrace.
7. Warn about saturation, background bias, different exposure settings or unsupported calibration instead of making up values.
8. All output crops/overlays/reports become derived Asset IDs. Original file cannot be modified in-place; explorer deletion remains separately audited.
