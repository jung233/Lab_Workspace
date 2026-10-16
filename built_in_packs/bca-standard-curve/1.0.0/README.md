# BCA standard curve (trusted built-in reference)

This version implements an unweighted ordinary least-squares linear fit, blank subtraction, inverse interpolation, explicit range QC, and the declared sample dilution factor. All numeric inputs are decimal strings and all fit intermediates are retained in the calculation trace.

The fixtures are synthetic software references. They do not validate a kit, instrument, wavelength, incubation condition, replicate policy, or usable concentration range. Pack results must be reviewed against the approved assay procedure. Out-of-range samples are retained with a warning and are never silently clamped or discarded.
