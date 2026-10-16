# Signed Calculation Pack Catalog v1

Community distribution in this implementation accepts HTTPS JSON catalogs and
declarative Calculation Pack documents. It does not download archives,
executables, Skills, native plugins, or Python source.

## Publisher trust

Before fetching a catalog, the user pins a 32-byte Ed25519 public key for a
publisher ID and independently checks the displayed SHA-256 fingerprint through
that publisher's trusted channel. Pins are stored in the device-local
`community_pack_publishers` table. Their key material and fingerprint are
immutable; disabling a pin is retained as a revisioned local change. A valid
signature from an unpinned key is rejected.

## Catalog envelope

The JSON object contains `schema_version` equal to
`lab-workspace-community-catalog-v1`, `publisher_id`, `key_fingerprint`, an
`entries` array, and a Base64 Ed25519 `signature`. The signature covers
canonical JSON of the complete object with only `signature` removed.

Each entry contains `pack_id`, `version`, `content_sha256`, `document_url`,
`signature`, a user-visible `description`, and `permissions`. The current
declarative Pack model has no publisher-granted privileges, so non-empty
permission lists are rejected. The document URL must be HTTPS and return a
Calculation Pack with matching ID/version and `status: draft`.

The per-Pack signature covers canonical JSON with these fields:

```json
{
  "schema_version": "lab-workspace-community-pack-v1",
  "publisher_id": "publisher.example",
  "pack_id": "example-pack",
  "version": "1.0.0",
  "content_sha256": "<64 lowercase hexadecimal characters>",
  "permissions": []
}
```

The document content hash, catalog digest, signature, schema/primitive
allowlist report, and golden cases are checked before showing an install
option. The approval dialog presents publisher, key fingerprint, content hash,
source URL, description, permission summary, and validation results. Installation
requires a separate exact user approval and re-enters the Calculation Pack
registry, which revalidates and reruns its golden fixtures. Publisher provenance
is retained alongside the locally signed and user-approved immutable Pack; it
does not grant execution trust by itself.

The format is intentionally limited to the repository's allowlisted
declarative Pack operations. It does not implement community Python, executable
plugins, archive inspection, or a central hosted marketplace.
