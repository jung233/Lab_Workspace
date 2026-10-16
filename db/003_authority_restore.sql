-- Lab Workspace additive schema migration v3.
-- Runtime equivalent is packages/lab_core/lib/src/persistence/migrations.dart.
-- Historical source events, approvals, and remote target epochs remain intact.

PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS local_installation_identity (
    singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1),
    active_device_id TEXT NOT NULL REFERENCES devices(device_id),
    authority_generation INTEGER NOT NULL CHECK(authority_generation > 0),
    initialized_at_utc TEXT NOT NULL,
    restored_from_backup_id TEXT
);

ALTER TABLE approval_receipts ADD COLUMN issuer_device_id TEXT REFERENCES devices(device_id);
ALTER TABLE approval_receipts ADD COLUMN authority_generation INTEGER;
ALTER TABLE ai_provider_profiles ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE ai_consent_receipts ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE todo_integration_state ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE todo_integration_state ADD COLUMN needs_reauthorization INTEGER NOT NULL DEFAULT 0
    CHECK(needs_reauthorization IN(0,1));
ALTER TABLE remote_targets ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1;
ALTER TABLE remote_target_epochs ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1;

UPDATE ai_consent_receipts
SET revoked_at_utc=COALESCE(revoked_at_utc,approved_at_utc);

CREATE TABLE IF NOT EXISTS remote_target_epoch_authorizations (
    target_id TEXT NOT NULL,
    epoch INTEGER NOT NULL,
    authority_generation INTEGER NOT NULL CHECK(authority_generation > 0),
    provider TEXT NOT NULL,
    endpoint_fingerprint TEXT NOT NULL,
    key_id TEXT,
    key_fingerprint TEXT,
    credential_secret_ref TEXT,
    encryption_secret_ref TEXT,
    approval_ref TEXT NOT NULL REFERENCES approval_receipts(approval_ref),
    authorized_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE,
    PRIMARY KEY(target_id,epoch,authority_generation),
    FOREIGN KEY(target_id,epoch) REFERENCES remote_target_epochs(target_id,epoch),
    CHECK(length(trim(endpoint_fingerprint))>0),
    CHECK((key_id IS NULL AND key_fingerprint IS NULL AND encryption_secret_ref IS NULL) OR
          (key_id IS NOT NULL AND key_fingerprint IS NOT NULL AND encryption_secret_ref IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_remote_epoch_authorizations_generation
    ON remote_target_epoch_authorizations(authority_generation,target_id,epoch);

CREATE TABLE IF NOT EXISTS remote_asset_deletion_reviews (
    source_event_id TEXT PRIMARY KEY REFERENCES sync_remote_events(event_id),
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    source_deletion_id TEXT NOT NULL,
    blob_sha256 TEXT NOT NULL CHECK(length(blob_sha256)=64),
    requested_scope TEXT NOT NULL CHECK(requested_scope IN('trash','purge')),
    source_approval_ref TEXT,
    reason TEXT,
    requested_at_utc TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN('pending','accepted','rejected','audit_only')),
    local_deletion_id TEXT REFERENCES deletion_records(deletion_id),
    local_approval_ref TEXT REFERENCES approval_receipts(approval_ref),
    reviewed_at_utc TEXT,
    resolution_note TEXT,
    dismissed_at_utc TEXT,
    dismissal_note TEXT,
    CHECK((requested_scope='trash' AND status IN('pending','accepted','rejected')) OR
          (requested_scope='purge' AND status='audit_only')),
    CHECK((status='pending' AND local_deletion_id IS NULL AND local_approval_ref IS NULL AND reviewed_at_utc IS NULL) OR
          (status='accepted' AND local_deletion_id IS NOT NULL AND local_approval_ref IS NOT NULL AND reviewed_at_utc IS NOT NULL) OR
          (status='rejected' AND local_deletion_id IS NULL AND local_approval_ref IS NULL AND reviewed_at_utc IS NOT NULL) OR
          (status='audit_only' AND local_deletion_id IS NULL AND local_approval_ref IS NULL AND reviewed_at_utc IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_remote_asset_deletion_review_state
    ON remote_asset_deletion_reviews(status,requested_at_utc);

CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_scope_immutable
    BEFORE UPDATE ON approval_receipts
    WHEN NEW.approval_ref IS NOT OLD.approval_ref OR
         NEW.action IS NOT OLD.action OR
         NEW.subject_type IS NOT OLD.subject_type OR
         NEW.subject_id IS NOT OLD.subject_id OR
         NEW.scope_json IS NOT OLD.scope_json OR
         NEW.approved_at_utc IS NOT OLD.approved_at_utc OR
         NEW.expires_at_utc IS NOT OLD.expires_at_utc OR
         NEW.command_id IS NOT OLD.command_id OR
         NEW.issuer_device_id IS NOT OLD.issuer_device_id OR
         NEW.authority_generation IS NOT OLD.authority_generation OR
         (OLD.revoked_at_utc IS NOT NULL AND NEW.revoked_at_utc IS NOT OLD.revoked_at_utc)
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt authority and scope are immutable'); END;

CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_no_delete
    BEFORE DELETE ON approval_receipts
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt history is retained for audit'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization is immutable; append a new generation'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorizations are retained for audit'); END;

CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_local_authority
    BEFORE INSERT ON approval_receipts
    WHEN NEW.issuer_device_id IS NOT
         (SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1) OR
         NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt must be issued by the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_ai_profile_local_authority_insert
    BEFORE INSERT ON ai_provider_profiles
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'AI provider profile must belong to the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_ai_consent_local_authority_insert
    BEFORE INSERT ON ai_consent_receipts
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'AI consent must belong to the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_todo_state_local_authority_insert
    BEFORE INSERT ON todo_integration_state
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1) OR
         NEW.primary_device_id IS NOT
         (SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'To Do profile must belong to the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_target_local_authority_insert
    BEFORE INSERT ON remote_targets
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'Remote target must belong to the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_local_authority_insert
    BEFORE INSERT ON remote_target_epochs
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'Remote target epoch must belong to the active local authority'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_local_approval
    BEFORE INSERT ON remote_target_epoch_authorizations
    WHEN NEW.authority_generation IS NOT
           (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1) OR
         NOT EXISTS (
           SELECT 1 FROM approval_receipts a
           WHERE a.approval_ref=NEW.approval_ref
             AND a.action='sync.epoch.reauthorize'
             AND a.subject_type='remote_target_epoch'
             AND a.subject_id=NEW.target_id || '@' || NEW.epoch
             AND a.issuer_device_id=(SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1)
             AND a.authority_generation=NEW.authority_generation
             AND a.revoked_at_utc IS NULL
             AND julianday(a.approved_at_utc) <= julianday(NEW.authorized_at_utc)
             AND (a.expires_at_utc IS NULL OR julianday(a.expires_at_utc) > julianday(NEW.authorized_at_utc))
             AND json_valid(a.scope_json)
             AND json_type(a.scope_json)='object'
             AND json_extract(a.scope_json,'$.target_id')=NEW.target_id
             AND json_type(a.scope_json,'$.epoch')='integer'
             AND json_extract(a.scope_json,'$.epoch')=NEW.epoch
             AND json_type(a.scope_json,'$.provider')='text'
             AND json_extract(a.scope_json,'$.provider')=NEW.provider
             AND json_type(a.scope_json,'$.endpoint_fingerprint')='text'
             AND json_extract(a.scope_json,'$.endpoint_fingerprint')=NEW.endpoint_fingerprint
             AND ((NEW.key_id IS NULL AND json_type(a.scope_json,'$.key_id')='null') OR
                  (NEW.key_id IS NOT NULL AND json_type(a.scope_json,'$.key_id')='text' AND
                   json_extract(a.scope_json,'$.key_id')=NEW.key_id))
             AND ((NEW.key_fingerprint IS NULL AND json_type(a.scope_json,'$.key_fingerprint')='null') OR
                  (NEW.key_fingerprint IS NOT NULL AND json_type(a.scope_json,'$.key_fingerprint')='text' AND
                   json_extract(a.scope_json,'$.key_fingerprint')=NEW.key_fingerprint))
             AND (SELECT count(*) FROM json_each(a.scope_json))=6
         )
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization requires an exact active local approval'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_asset_deletion_review_transition
    BEFORE UPDATE ON remote_asset_deletion_reviews
    WHEN NEW.source_event_id IS NOT OLD.source_event_id OR
         NEW.target_id IS NOT OLD.target_id OR
         NEW.asset_id IS NOT OLD.asset_id OR
         NEW.source_deletion_id IS NOT OLD.source_deletion_id OR
         NEW.blob_sha256 IS NOT OLD.blob_sha256 OR
         NEW.requested_scope IS NOT OLD.requested_scope OR
         NEW.source_approval_ref IS NOT OLD.source_approval_ref OR
         NEW.reason IS NOT OLD.reason OR
         NEW.requested_at_utc IS NOT OLD.requested_at_utc OR
         NOT ((OLD.status='pending' AND NEW.status IN('accepted','rejected')) OR
              (OLD.status=NEW.status AND OLD.status='audit_only' AND
               NEW.dismissed_at_utc IS NOT NULL AND OLD.dismissed_at_utc IS NULL))
    BEGIN SELECT RAISE(ABORT,'Remote deletion review has an invalid state transition'); END;

CREATE TRIGGER IF NOT EXISTS trig_remote_asset_deletion_review_no_delete
    BEFORE DELETE ON remote_asset_deletion_reviews
    BEGIN SELECT RAISE(ABORT,'Remote deletion review history is retained'); END;

PRAGMA user_version = 3;

COMMIT;
