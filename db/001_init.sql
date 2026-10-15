-- Lab Workspace V2.0: SQLite reference schema, local-only single-user Vault.
-- This file is a migration baseline; actual production migration ownership belongs to Drift.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE vaults (
  vault_id TEXT PRIMARY KEY,
  created_at_utc TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  integrity_threshold_bytes INTEGER NOT NULL DEFAULT 2147483648 CHECK(integrity_threshold_bytes >= 0)
);
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY, vault_id TEXT NOT NULL REFERENCES vaults(vault_id),
  display_name TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, lamport INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE projects (
  project_id TEXT PRIMARY KEY, title TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL DEFAULT 1, created_at_utc TEXT NOT NULL, deleted_at_utc TEXT
);
CREATE TABLE experiments (
  experiment_id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(project_id),
  title TEXT NOT NULL, note TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 1,
  created_at_utc TEXT NOT NULL, deleted_at_utc TEXT
);
CREATE TABLE protocols (
  protocol_id TEXT PRIMARY KEY, title TEXT NOT NULL, current_version TEXT,
  archived_at_utc TEXT
);
CREATE TABLE protocol_versions (
  protocol_id TEXT NOT NULL REFERENCES protocols(protocol_id), version TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), status TEXT NOT NULL CHECK(status IN('draft','approved','archived')),
  payload_sha256 TEXT NOT NULL, approved_at_utc TEXT, created_at_utc TEXT NOT NULL,
  PRIMARY KEY(protocol_id,version)
);
CREATE TRIGGER trig_protocol_approved_immutable BEFORE UPDATE ON protocol_versions
  WHEN OLD.approved_at_utc IS NOT NULL BEGIN
    SELECT RAISE(ABORT,'approved ProtocolVersion cannot be modified; create a new version');
  END;
CREATE TABLE experiment_runs (
  run_id TEXT PRIMARY KEY, experiment_id TEXT REFERENCES experiments(experiment_id),
  protocol_id TEXT, protocol_version TEXT, title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('draft','planned','running','paused','completed','failed','cancelled')),
  revision INTEGER NOT NULL DEFAULT 1, parameter_snapshot_json TEXT NOT NULL CHECK(json_valid(parameter_snapshot_json)),
  created_at_utc TEXT NOT NULL, started_at_utc TEXT, finished_at_utc TEXT,
  FOREIGN KEY(protocol_id,protocol_version) REFERENCES protocol_versions(protocol_id,version)
);
CREATE TABLE step_executions (
  step_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
  protocol_step_id TEXT, kind TEXT NOT NULL, title TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('pending','ready','running','waiting','paused','completed','skipped','failed')),
  planned_start_utc TEXT, started_at_utc TEXT, due_at_utc TEXT, completed_at_utc TEXT,
  expected_seconds INTEGER, revision INTEGER NOT NULL DEFAULT 1,
  captured_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(captured_json))
);
CREATE TABLE step_dependencies (
  step_id TEXT NOT NULL REFERENCES step_executions(step_id),
  required_step_id TEXT NOT NULL REFERENCES step_executions(step_id),
  PRIMARY KEY(step_id,required_step_id), CHECK(step_id<>required_step_id)
);
CREATE TABLE step_events (
  event_id TEXT PRIMARY KEY, step_id TEXT NOT NULL REFERENCES step_executions(step_id),
  event_type TEXT NOT NULL, event_data_json TEXT NOT NULL CHECK(json_valid(event_data_json)),
  occurred_at_utc TEXT NOT NULL, recorded_at_utc TEXT NOT NULL
);
CREATE TABLE experimental_groups (
  group_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
  title TEXT NOT NULL, conditions_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(conditions_json))
);
CREATE TABLE samples (
  sample_id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_sample_id TEXT REFERENCES samples(sample_id),
  properties_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(properties_json)),
  created_at_utc TEXT NOT NULL
);
CREATE TABLE run_samples (
  run_id TEXT NOT NULL REFERENCES experiment_runs(run_id), sample_id TEXT NOT NULL REFERENCES samples(sample_id),
  group_id TEXT REFERENCES experimental_groups(group_id), PRIMARY KEY(run_id,sample_id)
);
CREATE TABLE treatments (
  treatment_id TEXT PRIMARY KEY, sample_id TEXT NOT NULL REFERENCES samples(sample_id),
  run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
  conditions_json TEXT NOT NULL CHECK(json_valid(conditions_json)),
  applied_at_utc TEXT, corrected_from TEXT REFERENCES treatments(treatment_id), recorded_at_utc TEXT NOT NULL
);
CREATE TABLE blob_objects (
  sha256 TEXT PRIMARY KEY CHECK(length(sha256)=64), byte_size INTEGER NOT NULL CHECK(byte_size>=0),
  relative_path TEXT NOT NULL UNIQUE, state TEXT NOT NULL CHECK(state IN('staged','committed','missing','mismatch','purged')),
  imported_at_utc TEXT NOT NULL, last_full_verified_at TEXT, last_fast_checked_at TEXT,
  last_known_size INTEGER, last_known_mtime_ns INTEGER, last_file_id TEXT,
  threshold_at_import INTEGER NOT NULL DEFAULT 2147483648
);
CREATE TRIGGER trig_committed_blob_immutable BEFORE UPDATE OF sha256,byte_size,relative_path ON blob_objects
  WHEN OLD.state='committed' BEGIN SELECT RAISE(ABORT,'committed blob identity/contents are immutable'); END;
CREATE TABLE assets (
  asset_id TEXT PRIMARY KEY, blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
  display_name TEXT NOT NULL, media_type TEXT, kind TEXT NOT NULL CHECK(kind IN('raw','derived','report','thumbnail','export')),
  parent_asset_id TEXT REFERENCES assets(asset_id), created_at_utc TEXT NOT NULL, deleted_at_utc TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json))
);
CREATE TRIGGER trig_asset_blob_immutable BEFORE UPDATE OF blob_sha256 ON assets
  BEGIN SELECT RAISE(ABORT,'cannot replace content of an Asset; create a new Asset'); END;
CREATE TABLE asset_links (
  link_id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES assets(asset_id),
  entity_type TEXT NOT NULL CHECK(entity_type IN('run','step','sample','measurement','calculation','analysis')),
  entity_id TEXT NOT NULL, relation TEXT NOT NULL, removed_at_utc TEXT
);
CREATE INDEX idx_asset_links_entity ON asset_links(entity_type,entity_id);
CREATE TABLE deletion_records (
  deletion_id TEXT PRIMARY KEY, asset_id TEXT NOT NULL REFERENCES assets(asset_id),
  scope TEXT NOT NULL CHECK(scope IN('unlink','trash','purge')),
  impact_json TEXT NOT NULL CHECK(json_valid(impact_json)),
  state TEXT NOT NULL CHECK(state IN('requested','trashed','purged','recovered','blocked')),
  created_at_utc TEXT NOT NULL, purge_eligible_at_utc TEXT, reason TEXT
);
CREATE TABLE integrity_checks (
  check_id TEXT PRIMARY KEY, blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
  mode TEXT NOT NULL CHECK(mode IN('full_sha256','metadata_quick','transfer_checksum')),
  status TEXT NOT NULL CHECK(status IN('passed','failed','unknown')),
  started_at_utc TEXT NOT NULL, finished_at_utc TEXT, details_json TEXT NOT NULL CHECK(json_valid(details_json))
);
CREATE TABLE measurements (
  measurement_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
  step_id TEXT REFERENCES step_executions(step_id), sample_id TEXT REFERENCES samples(sample_id),
  analyte TEXT NOT NULL, value_text TEXT NOT NULL, unit TEXT, raw_asset_id TEXT REFERENCES assets(asset_id),
  state TEXT NOT NULL CHECK(state IN('draft_ai','recorded','user_confirmed','superseded')),
  superseded_by TEXT REFERENCES measurements(measurement_id), created_at_utc TEXT NOT NULL
);
CREATE TABLE calculation_packs (
  pack_id TEXT NOT NULL, version TEXT NOT NULL, manifest_sha256 TEXT NOT NULL,
  pipeline_json TEXT NOT NULL CHECK(json_valid(pipeline_json)),
  status TEXT NOT NULL CHECK(status IN('draft','validated','tested','approved','disabled')),
  created_at_utc TEXT NOT NULL, PRIMARY KEY(pack_id,version)
);
CREATE TABLE calculation_runs (
  calculation_id TEXT PRIMARY KEY, run_id TEXT REFERENCES experiment_runs(run_id),
  step_id TEXT REFERENCES step_executions(step_id), pack_id TEXT NOT NULL,
  pack_version TEXT NOT NULL, input_json TEXT NOT NULL CHECK(json_valid(input_json)),
  status TEXT NOT NULL CHECK(status IN('queued','preparing','running','completed','failed','cancelled','interrupted')),
  trace_json TEXT CHECK(trace_json IS NULL OR json_valid(trace_json)),
  result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
  result_asset_id TEXT REFERENCES assets(asset_id), started_at_utc TEXT, finished_at_utc TEXT,
  FOREIGN KEY(pack_id,pack_version) REFERENCES calculation_packs(pack_id,version)
);
CREATE TABLE analysis_runs (
  analysis_id TEXT PRIMARY KEY, source_asset_id TEXT NOT NULL REFERENCES assets(asset_id),
  run_id TEXT REFERENCES experiment_runs(run_id), model_job_id TEXT, roi_approval_json TEXT CHECK(json_valid(roi_approval_json)),
  calculation_id TEXT REFERENCES calculation_runs(calculation_id),
  status TEXT NOT NULL, approved_at_utc TEXT, created_at_utc TEXT NOT NULL
);
CREATE TABLE ai_jobs (
  ai_job_id TEXT PRIMARY KEY, kind TEXT NOT NULL, provider_id TEXT NOT NULL,
  model_id TEXT NOT NULL, api_mode TEXT NOT NULL CHECK(api_mode IN('responses','chat_completions')),
  skill_id TEXT, skill_version TEXT, state TEXT NOT NULL,
  request_meta_json TEXT NOT NULL CHECK(json_valid(request_meta_json)),
  response_json TEXT CHECK(response_json IS NULL OR json_valid(response_json)),
  consent_ref TEXT, created_at_utc TEXT NOT NULL, finished_at_utc TEXT
);
CREATE TABLE tool_invocations (
  tool_call_id TEXT PRIMARY KEY, ai_job_id TEXT NOT NULL REFERENCES ai_jobs(ai_job_id),
  tool_id TEXT NOT NULL, params_json TEXT NOT NULL CHECK(json_valid(params_json)),
  output_json TEXT CHECK(output_json IS NULL OR json_valid(output_json)),
  state TEXT NOT NULL, created_at_utc TEXT NOT NULL
);
CREATE TABLE installed_packs (
  pack_id TEXT NOT NULL, version TEXT NOT NULL, pack_kind TEXT NOT NULL,
  manifest_hash TEXT NOT NULL, approved_at_utc TEXT, state TEXT NOT NULL,
  PRIMARY KEY(pack_id,version)
);
CREATE TABLE installed_skills (
  skill_id TEXT NOT NULL, version TEXT NOT NULL, sha256 TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(skill_id,version)
);
CREATE TABLE local_tasks (
  task_id TEXT PRIMARY KEY, step_id TEXT REFERENCES step_executions(step_id),
  title TEXT NOT NULL, due_at_utc TEXT, state TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE reminders (
  reminder_id TEXT PRIMARY KEY, task_id TEXT REFERENCES local_tasks(task_id),
  step_id TEXT REFERENCES step_executions(step_id), due_at_utc TEXT NOT NULL,
  device_notification_id TEXT, status TEXT NOT NULL, last_attempt_at_utc TEXT
);
CREATE TABLE todo_links (
  task_id TEXT PRIMARY KEY REFERENCES local_tasks(task_id), ms_list_id TEXT,
  ms_task_id TEXT, ms_etag TEXT, status TEXT NOT NULL, updated_at_utc TEXT
);
CREATE TABLE mutation_events (
  event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL REFERENCES devices(device_id),
  seq INTEGER NOT NULL, lamport INTEGER NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL,
  base_revision INTEGER, action TEXT NOT NULL, payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  created_at_utc TEXT NOT NULL, UNIQUE(device_id,seq)
);
CREATE TABLE sync_conflicts (
  conflict_id TEXT PRIMARY KEY, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL,
  event_id_a TEXT NOT NULL, event_id_b TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('open','resolved')),
  resolution_event_id TEXT, created_at_utc TEXT NOT NULL
);
CREATE TABLE remote_targets (
  target_id TEXT PRIMARY KEY, provider TEXT NOT NULL CHECK(provider IN('onedrive','s3')),
  policy_json TEXT NOT NULL CHECK(json_valid(policy_json)),
  secret_ref TEXT, epoch INTEGER NOT NULL DEFAULT 1, created_at_utc TEXT NOT NULL
);
CREATE TABLE remote_replicas (
  replica_id TEXT PRIMARY KEY, target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
  blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256), remote_object_key TEXT NOT NULL,
  encryption_mode TEXT NOT NULL, last_transfer_checksum TEXT,
  state TEXT NOT NULL, verified_at_utc TEXT, UNIQUE(target_id,blob_sha256,remote_object_key)
);
CREATE TABLE sync_cursors (
  target_id TEXT NOT NULL REFERENCES remote_targets(target_id), device_id TEXT NOT NULL,
  received_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(target_id,device_id)
);
CREATE TABLE backup_snapshots (
  backup_id TEXT PRIMARY KEY, target_id TEXT REFERENCES remote_targets(target_id),
  state TEXT NOT NULL, manifest_sha256 TEXT NOT NULL,
  encryption_mode TEXT NOT NULL, created_at_utc TEXT NOT NULL, last_restored_test_at_utc TEXT
);
CREATE TABLE outbox (
  outbox_id TEXT PRIMARY KEY, event_type TEXT NOT NULL, payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  idempotency_key TEXT NOT NULL UNIQUE, next_attempt_at_utc TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN('pending','in_progress','sent','failed')),
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT
);
CREATE INDEX idx_reminders_due ON reminders(status,due_at_utc);
CREATE INDEX idx_asset_deleted ON assets(deleted_at_utc);
CREATE INDEX idx_outbox_pending ON outbox(state,next_attempt_at_utc);
CREATE INDEX idx_run_steps ON step_executions(run_id,state);
CREATE INDEX idx_mutation_events_device_seq ON mutation_events(device_id,seq);
