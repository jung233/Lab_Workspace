---
name: lab-workspace-workflow-author
description: Build new no-code Lab Workspace V2.0 Calculation Packs and reusable lab workflows from natural-language requests without editing application source code. Use for new BCA concentration calculators, western blot loading calculations, dilution plans, plate analysis, sample transformations, unit conversions, and experiments requiring declarative formulas and pipeline validation. Identify missing computational primitives instead of writing unsafe auto-executed Python.
---

# Lab Workspace Workflow Pack Author

Create or update a **declarative Calculation Pack** using allowed, versioned PrimitiveRegistry operations. Output a Pack draft that can be installed via the App Pack Registry after schema validation, golden tests and explicit user approval.

## Workflow

1. Translate the user request into **inputs, type/unit, primitive operations, quality gates, outputs and downstream bindings**. Collect instrument file format / required columns / sample-to-well mapping if known.
2. Read `references/calculation-pack-v2.schema.json` and `references/primitive-registry.json` before proposing operators. Each `op` must exist in the registry with an exact `@version`. Missing operations become `unsupported_operations` with a clear requirement; never hallucinate a Python function or silently substitute an invalid statistical method.
3. Build an acyclic `pipeline` using `$inputs.FIELD` and `$steps.STEP_ID.FIELD` references. Use safe data bindings, deterministic parameters and explicit unit conversions. Never use unrestricted eval, external file paths, shell or arbitrary source code as a pack operation.
4. Create a data entry form description, a synthetic or deidentified fixture, expected numerical outputs, tolerances and a `CalculationTrace` plan. Do not hard-code previous research sample measurements as new experiment defaults.
5. Add method warnings: e.g. BCA blank handling, linear vs nonlinear fit, range extrapolation, replicate wells, invalid quality controls. An AI-generated Pack is **not** an automatically validated scientific method.
6. Validate pipeline Schema, identifier uniqueness, reference dependencies, versioned primitives and golden tests. `scripts/validate_workflow.py` validates a draft against the packaged initial registry; actual execution tests require the App PrimitiveEngine.
7. Show the user a step-by-step original-calculation preview from deterministic test execution, the proposed output binding and a concise list of unresolved scientific decisions. Only after explicit review may Lab Workspace install it as a versioned Pack.
8. For brand-new code beyond the known primitives, generate a **development request**; Windows may permit a trusted user-approved external Python plugin, but iOS/Android cannot be promised on-the-fly native code installation. This Skill alone must not write or execute arbitrary plugin code.

## Output

Use `references/bca-pipeline-example.json` as a concrete model. Produce a versioned `pipeline.json` and `forms.json`, test fixtures, and a manifest listing exact file SHA-256; separate source documents from generated configuration. The app must assign a new immutable Pack version on each update.

## Safety

Treat prompt, SOP and model output as untrusted until validated; require permission before external AI uploads; do not change confirmed historical calculations or run arbitrary Python. Never claim the Pack was tested unless an actual deterministic test result exists.
