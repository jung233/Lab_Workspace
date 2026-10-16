# Western blot ROI normalization (trusted built-in reference)

Computes the target/reference intensity ratio and divides it by an explicit calibrator ratio. It never detects bands or chooses ROIs. Intensities must be derived from a separate human-approved ROI calculation bound to the source image SHA and original-pixel trace.

This is arithmetic only. The user must select the reference and calibrator according to the approved experiment procedure and inspect saturation, background handling, exposure, and source integrity warnings.
