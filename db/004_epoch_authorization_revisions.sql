-- Lab Workspace additive schema migration v4.
-- Revoked or expired local epoch grants remain in history; a renewed grant is
-- appended as a higher revision and must have a fresh credential/key ref.

PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_local_approval;
DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_no_update;
DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_no_delete;
DROP INDEX IF EXISTS idx_remote_epoch_authorizations_generation;

ALTER TABLE remote_target_epoch_authorizations
    RENAME TO remote_target_epoch_authorizations_v3;

CREATE TABLE remote_target_epoch_authorizations (
    authorization_id TEXT NOT NULL UNIQUE,
    authorization_revision INTEGER NOT NULL CHECK(authorization_revision > 0),
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
    PRIMARY KEY(target_id,epoch,authority_generation,authorization_revision),
    FOREIGN KEY(target_id,epoch) REFERENCES remote_target_epochs(target_id,epoch),
    CHECK(length(trim(endpoint_fingerprint))>0),
    CHECK((key_id IS NULL AND key_fingerprint IS NULL AND encryption_secret_ref IS NULL) OR
          (key_id IS NOT NULL AND key_fingerprint IS NOT NULL AND encryption_secret_ref IS NOT NULL))
);

INSERT INTO remote_target_epoch_authorizations
    (authorization_id,authorization_revision,target_id,epoch,authority_generation,provider,
     endpoint_fingerprint,key_id,key_fingerprint,credential_secret_ref,encryption_secret_ref,
     approval_ref,authorized_at_utc,command_id)
SELECT 'legacy:' || target_id || ':' || epoch || ':' || authority_generation,1,target_id,epoch,
       authority_generation,provider,endpoint_fingerprint,key_id,key_fingerprint,credential_secret_ref,
       encryption_secret_ref,approval_ref,authorized_at_utc,command_id
FROM remote_target_epoch_authorizations_v3;

CREATE INDEX idx_remote_epoch_authorizations_generation
    ON remote_target_epoch_authorizations(target_id,epoch,authority_generation,authorization_revision DESC);

CREATE TRIGGER trig_remote_epoch_authorization_local_approval
    BEFORE INSERT ON remote_target_epoch_authorizations
    WHEN NEW.authority_generation IS NOT
           (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1) OR
         NOT EXISTS (
           SELECT 1 FROM approval_receipts a
           JOIN remote_target_epochs e ON e.target_id=NEW.target_id AND e.epoch=NEW.epoch
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
             AND json_extract(e.policy_json,'$.provider')=NEW.provider
             AND json_type(a.scope_json,'$.endpoint_fingerprint')='text'
             AND json_extract(a.scope_json,'$.endpoint_fingerprint')=NEW.endpoint_fingerprint
             AND ((NEW.key_id IS NULL AND json_type(a.scope_json,'$.key_id')='null') OR
                  (NEW.key_id IS NOT NULL AND json_type(a.scope_json,'$.key_id')='text' AND
                   json_extract(a.scope_json,'$.key_id')=NEW.key_id))
             AND ((NEW.key_fingerprint IS NULL AND json_type(a.scope_json,'$.key_fingerprint')='null') OR
                  (NEW.key_fingerprint IS NOT NULL AND json_type(a.scope_json,'$.key_fingerprint')='text' AND
                   json_extract(a.scope_json,'$.key_fingerprint')=NEW.key_fingerprint))
             AND (SELECT count(*) FROM json_each(a.scope_json))=6
             AND NEW.key_id IS json_extract(e.policy_json,'$.key_id')
             AND NEW.credential_secret_ref IS NOT NULL
             AND NEW.credential_secret_ref IS NOT e.secret_ref
             AND (NEW.key_id IS NULL OR NEW.encryption_secret_ref IS NOT json_extract(e.policy_json,'$.key_id'))
         )
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization requires fresh references and exact active local approval'); END;

CREATE TRIGGER trig_remote_epoch_authorization_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization is immutable; append a new revision'); END;

CREATE TRIGGER trig_remote_epoch_authorization_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorizations are retained for audit'); END;

CREATE TRIGGER trig_remote_epoch_authorization_v3_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations_v3
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization audit is immutable'); END;

CREATE TRIGGER trig_remote_epoch_authorization_v3_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations_v3
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization audit is retained'); END;

PRAGMA user_version = 4;

COMMIT;
