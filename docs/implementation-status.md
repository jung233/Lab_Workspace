# Lab Workspace V2.0 implementation status

Status date: 2026-10-15. This document tracks engineering work against the V2.0
specification. It does not replace the frozen requirements in
`Lab_Workspace_V2.0_Complete_Development_Document.md` or `docs/00` through
`docs/09`.

## Baseline

The repository began as an engineering specification and reference kit, not a
native application. It contains JSON Schemas, examples, SQLite reference DDL,
Python demonstrations, Skill validators, and reference checks. It did not
contain Flutter application or Dart package source at the start of the V2.0
implementation. The examples and demonstrations are not production services.

## Implementation ownership

| Area | Owner | Scope |
|---|---|---|
| Shared package, domain, persistence, application | core | `packages/lab_core/lib/src/{domain,persistence,application}/`, package manifest and public exports |
| Asset store, Explorer, sync and backup | storage | asset gateway, CAS, integrity, deletion/GC, sync, cloud, snapshot and restore |
| Calculation and Pack runtime | calculation | calculation engine, trace, scientific units, Pack validation/registry, built-in Packs, Python runner |
| AI, image orchestration, integrations | requirements | `packages/lab_core/lib/src/{ai,image,integrations}/`, static acceptance helper, this status document |
| Native app shell, unrelated UI and platform bridges | native_audit | `apps/lab_workspace/**` except delegated integration screens |
| AI, image and To Do app screens | requirements | `apps/lab_workspace/lib/src/ai_image/**`, `apps/lab_workspace/lib/integrations/**` |

All feature work is expected to use the shared package's public APIs and the
frozen schema contracts. Cross-module behavior must fail closed on missing
consent, unsupported operations, missing approvals, or incomplete recovery
material.

## Requirement coverage by specification chapter

| Specification chapter | Requirement scope | Implementation evidence | Static status and remaining evidence |
|---|---|---|---|
| `docs/00-scope-decisions.md` | Lab Workspace branding; Windows, Android, iOS native; local-first single user; optional remote services | `apps/lab_workspace/**`, `packages/lab_core/**` (being added by implementation owners) | Native package manifests, routes and platform bridge declarations have been statically reviewed; no platform build or device verification was run. |
| `docs/01-architecture-and-directory.md` | Local SQLite Vault, shared pure-Dart core, native adapters, versioned migrations, offline operation | `packages/lab_core/lib/src/persistence/{workspace_database,migrations}.dart`, `apps/lab_workspace/**` | SQLite persistence and additive migrations through schema v4 exist in source, including installation authority generations and current-generation approval/credential isolation. Native startup and platform path wiring are present and analyzer-clean; Vault restore activation still requires runtime/device acceptance. |
| `docs/02-domain-and-protocol.md` | Projects, Experiments, Protocols, Runs, groups, samples, treatments, schedule, reminders, corrections | `packages/lab_core/lib/src/domain/**`, `packages/lab_core/lib/src/application/**`, schema contracts | TaskService transaction-scoped create/update/soft-delete APIs emit standard local task mutation events so remote To Do import can atomically commit task, link, conflict, and cursor state. Remote measurement/calculation projection is quarantined and requires explicit review before becoming trusted local evidence. Final mapping of every domain and UI flow remains pending whole-app acceptance. |
| `docs/03-workflow-packs-and-skills.md` | Declarative versioned Packs, Skill instructions, approval, primitive allowlist, no arbitrary generated code | `packages/lab_core/lib/src/ai/{pack_draft_service,calculation_pack_review_adapter,skill_registry,sqlite_pack_draft_repository,sqlite_skill_registry_repository}.dart`, `packages/lab_core/lib/src/packs/**`, `apps/lab_workspace/lib/src/ai_image/ai_image_page.dart` | Draft persistence, Skill versioning, concrete schema/golden/registry adapter and explicit app approval UI exist. Generated drafts cannot execute through the draft service; registry installation requires fresh validation, golden cases and an exact approval receipt. |
| `docs/04-asset-explorer-integrity.md` | Immutable content-addressed assets, full SHA versus quick checks, Explorer, deletion impact and GC | `packages/lab_core/lib/src/assets/**`, `packages/lab_core/lib/src/image/{image_analysis_service,python_image_quantifier}.dart`, `apps/lab_workspace/lib/src/ai_image/{png_image_platform,png_derived_image_tools}.dart` | Asset Explorer, deletion-impact review and storage analysis UI/services exist. Verified original-only PNG/TIFF preview/decoders and reviewed ROI extraction are connected. The pinned Dart image decoder handles selected TIFF pages with unsigned 8/16-bit grayscale/RGB channels while preserving integer samples. Alpha-bearing PNG/TIFF, palette, signed, floating, CMYK and other unsupported TIFF layouts are rejected before upload. Approved crop/overlay/export create separate derived/report Assets. Source review confirms AssetLink/reference and lease/tombstone-aware GC paths; destructive-operation runtime acceptance remains pending. |
| `docs/05-sync-backup-optional-encryption.md` | Event/blob sync, no live SQLite file sync, independent snapshots, optional encryption and recovery | `packages/lab_core/lib/src/sync/**`, `packages/lab_core/lib/src/backup/**`, `apps/lab_workspace/lib/integrations/microsoft_identity.dart` | OneDrive has an independent Files.ReadWrite device-code OAuth profile and secure token rotation; To Do credentials are not reused. Storage sources implement event/blob sync, SigV4 S3 multipart, Online Backup snapshots, class-selective plaintext/encrypted backup and verified restore into a new directory. S3 settings write credentials only through Flutter secure storage and give SyncService an opaque SecretRef. The shared tree now has additive local-installation authority generation and restore identity rotation. Current AI/To Do/image approval receipts are issuer-device/generation-bound; restored AI and To Do credentials are revoked or cleared, and restored OneDrive targets require a fresh per-generation authorization overlay while historical epoch records remain auditable. The v4 per-epoch authorization revision path is implemented and the full core analyzer is clean. Post-publish source-audit failures return an explicit warning while preserving the successful destination result. Plain/encrypted restore, historical epoch selection/reauthorization, and fresh local authority are implemented in source; no cloud connection, upload or restore was exercised, so provider/device/recovery acceptance remains runtime-unverified. |
| `docs/06-python-ai-image-trace.md` | Trusted Python, official OpenAI SDK, separate Responses/Chat adapters, consent, tool loop, image ROI, immutable trace | `packages/lab_core/lib/src/ai/**`, `packages/lab_core/lib/src/image/**`, `apps/lab_workspace/lib/src/ai_image/**`, `python/ai_provider_sdk_bridge.py`, `python/runner/calculation_rpc.py`, `contracts/image-calculation-trace-v2.schema.json`, `tooling/build_image_trace_schema.py` | Consent-gated Responses/Chat requests, a no-network SDK configuration probe, verified 8/16-bit PNG/TIFF integer decoders, page/channel/ROI/background review, Calculation RPC adapter, derived handlers, Pack review and signed catalog UI are present. The probe was not run. Windows runners are explicitly configured; mobile Python uses the native trusted runtime bridge and remains unverified on devices. Unsupported TIFF layouts and non-PNG/TIFF formats are rejected before upload. ROI results have a typed, hash-verified image CalculationTrace and “展示原始计算” action over the report Asset. |
| `docs/07-security-release-tests.md` | Secret isolation, least privilege, safe release, security gates and test policy | `packages/lab_core/lib/src/domain/security.dart`, AI repositories/bridge, `tooling/static_acceptance_report.py`, `apps/lab_workspace/lib/src/ai_image/**`, `apps/lab_workspace/lib/integrations/**`, `apps/lab_workspace/lib/screens/provider_settings_page.dart` | Credentials remain behind secure-store references; direct AI HTTPS and preview uploads require exact consent. A local no-network provider probe is implemented but was not executed. This session did not run tests or launch the app. Restore activation rotates `local_installation_identity` authority generation and active device; AI/To Do/ROI approvals require current issuer/generation, and provider/consent/To Do state lookups reject prior-generation records. Mobile calculation bridge, native notifications and platform security require device verification. |
| `docs/08-implementation-contracts.md` | Contracts, stable error handling, event/migration compatibility, references and artifacts | `contracts/**`, `db/002_core_extensions.sql`, `packages/lab_core/lib/src/persistence/migrations.dart`, module APIs | AI, image, Skill, Pack draft and To Do repositories are mapped to versioned tables; image trace contract is independently versioned and stored as a report Asset linked to the original and analysis. The full core package analyzer (`dart analyze lib`) reports no issues after To Do, v4 epoch authorization and restore-generation changes. The final full-app `flutter analyze --no-pub` reports no issues; `git diff --check` also reports no whitespace errors. |
| `docs/09-verified-technology-references.md` | Primary-source technology constraints and supported provider/Graph capabilities | `packages/lab_core/lib/src/ai/**`, `packages/lab_core/lib/src/integrations/microsoft_graph_todo_client.dart`, `apps/lab_workspace/lib/integrations/**` | Graph v1.0 To Do task/open-extension/ETag flows, paginated `/me/todo/lists` discovery and independent OneDrive Files.ReadWrite OAuth device-code/refresh are implemented in source. Live use requires registered public-client apps and delegated Graph permissions; no live account verification was performed. |

### AI, image, and Microsoft To Do implementation detail

| Capability | Source evidence | Static state |
|---|---|---|
| Responses and Chat Completions are separate adapters | `src/ai/provider_adapters.dart` | Implemented as separate wire formats; Responses requests use `store:false` and local in-memory history. |
| Provider capability detection | `python/ai_provider_sdk_bridge.py`, `src/ai/openai_python_sdk_bridge.dart` | Synthetic probes cover text, tools, JSON schema, and one-pixel vision; image editing and streaming stay `unknown`. Probe may incur provider charges and therefore requires explicit synthetic-data consent. |
| Credentials and consent | `src/ai/models.dart`, `src/ai/ai_provider_service.dart`, `src/ai/sqlite_ai_repositories.dart`, `apps/lab_workspace/lib/src/ai_image/ai_image_page.dart` | Only `SecretRef` is stored in SQLite. Text, synthetic probe, Pack generation and image-preview requests each show provider/purpose/data class/assets/byte cap/scopes and require a durable, scope-checked approval receipt. AI profiles/consents remain device-local. |
| Bounded tool loop and Skills | `src/ai/ai_provider_service.dart`, `src/ai/sqlite_ai_repositories.dart`, `src/ai/skill_registry.dart`, `src/ai/sqlite_skill_registry_repository.dart` | Registered tools only, conservative JSON-schema argument validation, exact parameter/Asset-bound persisted approval validation, bounded rounds, instruction-only versioned Skills. |
| Pack generation | `src/ai/pack_draft_service.dart`, `src/ai/calculation_pack_review_adapter.dart`, `src/ai/sqlite_pack_draft_repository.dart`, `src/packs/**`, `apps/lab_workspace/lib/src/ai_image/ai_image_page.dart` | Generated documents are forced to draft and persisted. The app displays validation errors/unsupported operations, then explicitly approves installation; the registry revalidates and runs golden cases before freezing the immutable hash. Drafts remain device-local and untrusted until registry installation. |
| Community Pack catalog | `src/ai/community_pack_catalog.dart`, `src/packs/calculation_pack_registry.dart`, `docs/community-pack-catalog-v1.md`, `apps/lab_workspace/lib/src/ai_image/{ai_image_page,http_community_pack_transport}.dart` | HTTPS JSON catalogs and declarative documents use pinned Ed25519 publisher keys; catalog/content hashes, schema/primitive allowlist, empty permissions and golden cases are checked. The app displays publisher/key/hash/permission summary and requires separate exact approval; the local registry records publisher provenance and signs the immutable installed version. Executable plugins, archive distributions and a central marketplace are not implemented. |
| Image planning and ROI review | `src/image/{image_tool_registry,image_analysis_service,sqlite_image_plan_repository,python_image_quantifier,image_calculation_trace}.dart`, `contracts/image-calculation-trace-v2.schema.json`, `python/runner/calculation_rpc.py`, `apps/lab_workspace/lib/src/ai_image/{ai_image_page,png_image_platform,png_derived_image_tools}.dart` | User consents before preview upload; selected TIFF page and model-proposed ROIs are reviewed in original coordinates with optional background ROI, channel and method. Full-SHA immutable original is decoded and only selected integer pixels reach `quantifyRoi`. The typed versioned trace validator binds source SHA/integrity, page/channel/ROI, approval, primitive version/build identity and pinned source-bundle SHA-256, exact integer sample hashes, intermediate results, rounding, outputs and warnings. Trace report is a separate SHA-addressed Asset linked to source and analysis; review persists trace ID and report Asset ID and the UI verifies hash before display/export. PNG and selected TIFF page decoders preserve 8/16-bit integer values. Unsupported TIFF layouts, JPEG and unsupported PNG data are rejected before upload. Windows runner has UI configuration; Android/iOS trusted-runtime bridge wiring is present in source, while device execution remains unverified. Plans/ROI approvals are device-local. |
| Microsoft To Do | `src/integrations/{microsoft_todo_sync_service,sqlite_microsoft_todo_repository,microsoft_graph_todo_client,microsoft_todo_import_service}.dart`, `apps/lab_workspace/lib/integrations/{microsoft_identity,microsoft_todo_page}.dart` | Alongside paginated `/me/todo/lists` discovery and confirmed push, an explicit default-off import option reads Graph task delta pages and commits TaskService events, account-scoped links, immutable conflict snapshots and the final delta cursor in one transaction. ETag/local-revision conflicts offer keep-local, accept-remote or ignore-remote review; imported revisions do not loop back to push, and remote deletions use soft-delete. Distinct repeated delta snapshots are quarantined and resolved against a fresh current-task read; expired cursors are conditionally cleared and require a visible retry that performs a full state reconciliation. The account scope is a local hash of tenant, public client ID, selected list and opaque credential-session reference; it is not asserted to be a Microsoft account identifier. New login/list scopes do not reuse old scoped links; app UI warns that rebuilding requires a separately confirmed sync preview. Changing list, OAuth client, tenant or secret reference clears the prior delta cursor. OAuth app registration is user-provided; provider profile, token reference, selected list, remote links, delta cursor and conflict snapshots remain device-local. No live account/delta flow was exercised. |

### Implementation limits and acceptance still outstanding

Static source review and the core/app analyzers found no known unimplemented requirement in the agreed native Lab Workspace scope. Explicit implementation limits are rejected before upload: scientific image quantification accepts the supported unsigned 8/16-bit PNG/TIFF grayscale/RGB layouts only; other image formats and unsupported TIFF layouts need a trusted decoder extension. A public marketplace and executable third-party plugins are not implemented; the community catalog distributes signed declarative Packs over HTTPS. Windows Python configuration and Android/iOS trusted-runtime bridges are implemented in source, but platform execution has not been verified. Microsoft OAuth, Graph sync, cloud storage, remote restore, native notifications, encryption and cross-device conflict behavior remain unverified at runtime. The requested no-tests constraint was followed.

## Static acceptance gates

- Keep the product native and local-first; do not add a web frontend, central
  business backend, multi-user authentication, or mandatory Docker runtime.
- Preserve schema versioning and migration paths; never mutate approved
  Protocol versions or historical calculation results in place.
- Route external model calls through an explicit consent receipt listing the
  provider, approved assets, data class, estimated size and applicable policy.
- Keep credentials behind an opaque reference and a platform secure-store
  interface; exclude secret values from database records, event payloads, logs,
  Packs and backups.
- Reject unknown tools and calculation operations. AI-generated Packs remain
  drafts until schema validation, supported-op validation, golden verification
  and user approval complete.
- Image quantification must require a user-approved ROI and an immutable
  original asset. Generated or edited pixels cannot enter quantitative paths.
- Every computed scientific value must retain its CalculationTrace and expose
  the required “展示原始计算” action in the client.
- Distinguish full SHA verification from metadata quick checks. Deletion and
  physical GC must account for every Asset reference, retained backups, remote
  tombstones and active jobs.
- Do not synchronize a live SQLite database file. Keep event/blob sync separate
  from independently restorable snapshots; plaintext and encrypted recovery
  must both remain supported.
- Static review is not evidence that native notifications, mobile Python,
  remote restore, encryption security or cross-device conflict handling work at
  runtime. Those claims require later platform and recovery acceptance.

## Verification policy

The current implementation request prohibits running tests or launching the
application. The static marker inventory reported 11/11 evidence locations, but that is not
functional acceptance. The full core package analyzer (`dart analyze lib`) is clean after the current restore-generation edits. The final full-app `flutter analyze --no-pub` is clean, and `git diff --check` reports no whitespace errors. The repository request prohibits tests and app launch, and neither was run. Record only source
inspection and static checks here; do not describe unrun tests as passing.
Runtime, device, security and recovery claims remain pending until separately
verified.
