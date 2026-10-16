# Western blot loading volume (trusted built-in reference)

Computes sample volume as target protein mass divided by a user-provided, confirmed concentration. It checks the result against an explicitly entered maximum sample volume and keeps the value with a warning when it is outside the limit.

The built-in does not infer the target mass, total well volume, buffer volume, or assay protocol. The concentration should be bound to its upstream BCA CalculationRun and verified input snapshot by the workflow service.
