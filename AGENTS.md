# Lab Workspace AI coding-agent rules

## Architecture invariants

- Product branding is **Lab Workspace**, not BioLab Workspace. Support Windows + Android + iOS native apps only; no web frontend, central backend, multi-user auth or mandatory Docker.
- Every device owns a local SQLite database and content-addressed AssetStore. Never sync a live SQLite database file via OneDrive/S3; only exchange immutable events and blobs, and snapshot the database using the SQLite Online Backup API.
- Files must be assigned SHA-256 on ingest. The default strict-access threshold is 2 GiB, configurable. On logical read: full SHA for smaller assets; metadata quick check for larger assets unless manually/periodically requested. Display that quick check is not SHA verification.
- Add an explicit File Explorer with system-open, virtual folders, references, soft deletion, permanent deletion impact preview, GC, and storage usage analysis. Never blindly delete a shared CAS blob when multiple Assets reference it.
- Remote client-side encryption is optional per destination and file class. Both encrypted and plaintext backup recovery must work, with clear key dependency warnings.
- All derived scientific numbers must retain a CalculationTrace that feeds a mandatory “展示原始计算” UI action. Never present unreviewed AI guesses as exact scientific calculations.
- All protocol/workflow extension should prefer versioned declarative Packs and approved primitive operations. Do not add an experiment-specific hardcoded module for every new protocol. Reject unsupported operations rather than executing model-produced Python automatically.
- Multimodal models choose and explain image tools. Never implement an automatic local CV detector/segmenter or use generated/edited image pixels for quantitative evidence. Quantitative pixel arithmetic is permitted only with explicit, reviewed ROIs on immutable originals.
- Prefer official OpenAI Python SDK, support Responses and Chat Completions via separate adapters; probe vendor capabilities and require upload consent. Do not embed API keys in apps or backups.
- Windows may use bundled or explicitly configured Python/Conda. Android/iOS embed trusted Python; do not promise arbitrary new native Python package installation at runtime.
- No schema breaking changes without migrations and new versions; do not modify immutable approved Protocol Versions or prior CalculationRun results in place.

## Development workflow

Read `docs/00-scope-decisions.md` through `docs/08-implementation-contracts.md` before modifying domain or storage behavior. Validate examples against `contracts/` and run `python -m unittest discover -s tests -v` after refactoring the reference code. Keep lockfiles pinned, avoid network calls in tests, and use synthetic BCA/WB fixtures only.

## QA blocker gates

- SHA mismatch undetected; large-file quick check mislabeled as cryptographic verified.
- Missing calculation trace button or silent rewriting of previous results.
- Missing user consent before cloud image upload.
- Unapproved generated Protocol/Calculation Pack running in live experiment.
- Delete action bypassing AssetLink impact analysis.
- Encryption mandatory or plaintext backup impossible to restore independently.
