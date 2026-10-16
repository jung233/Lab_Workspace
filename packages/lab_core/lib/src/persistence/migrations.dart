/// Runtime form of the immutable reference schema in db/001_init.sql followed
/// by additive schema version 2 changes in db/002_core_extensions.sql.
///
/// Keep these statements in lockstep with the checked-in SQL migration files.
const int currentSchemaVersion = 4;

const List<String> initialSchemaStatements = [
  '''CREATE TABLE IF NOT EXISTS vaults (
    vault_id TEXT PRIMARY KEY,
    created_at_utc TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    integrity_threshold_bytes INTEGER NOT NULL DEFAULT 2147483648
      CHECK(integrity_threshold_bytes >= 0)
  )''',
  '''CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id),
    display_name TEXT NOT NULL,
    seq INTEGER NOT NULL DEFAULT 0,
    lamport INTEGER NOT NULL DEFAULT 0
  )''',
  '''CREATE TABLE IF NOT EXISTS projects (
    project_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1,
    created_at_utc TEXT NOT NULL,
    deleted_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS experiments (
    experiment_id TEXT PRIMARY KEY,
    project_id TEXT REFERENCES projects(project_id),
    title TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1,
    created_at_utc TEXT NOT NULL,
    deleted_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS protocols (
    protocol_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    current_version TEXT,
    archived_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS protocol_versions (
    protocol_id TEXT NOT NULL REFERENCES protocols(protocol_id),
    version TEXT NOT NULL,
    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
    status TEXT NOT NULL CHECK(status IN('draft','approved','archived')),
    payload_sha256 TEXT NOT NULL,
    approved_at_utc TEXT,
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(protocol_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS experiment_runs (
    run_id TEXT PRIMARY KEY,
    experiment_id TEXT REFERENCES experiments(experiment_id),
    protocol_id TEXT,
    protocol_version TEXT,
    title TEXT NOT NULL,
    state TEXT NOT NULL
      CHECK(state IN('draft','planned','running','paused','completed','failed','cancelled')),
    revision INTEGER NOT NULL DEFAULT 1,
    parameter_snapshot_json TEXT NOT NULL CHECK(json_valid(parameter_snapshot_json)),
    created_at_utc TEXT NOT NULL,
    started_at_utc TEXT,
    finished_at_utc TEXT,
    FOREIGN KEY(protocol_id,protocol_version)
      REFERENCES protocol_versions(protocol_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS step_executions (
    step_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    protocol_step_id TEXT,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    state TEXT NOT NULL
      CHECK(state IN('pending','ready','running','waiting','paused','completed','skipped','failed')),
    planned_start_utc TEXT,
    started_at_utc TEXT,
    due_at_utc TEXT,
    completed_at_utc TEXT,
    expected_seconds INTEGER,
    revision INTEGER NOT NULL DEFAULT 1,
    captured_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(captured_json))
  )''',
  '''CREATE TABLE IF NOT EXISTS step_dependencies (
    step_id TEXT NOT NULL REFERENCES step_executions(step_id),
    required_step_id TEXT NOT NULL REFERENCES step_executions(step_id),
    PRIMARY KEY(step_id,required_step_id),
    CHECK(step_id<>required_step_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS step_events (
    event_id TEXT PRIMARY KEY,
    step_id TEXT NOT NULL REFERENCES step_executions(step_id),
    event_type TEXT NOT NULL,
    event_data_json TEXT NOT NULL CHECK(json_valid(event_data_json)),
    occurred_at_utc TEXT NOT NULL,
    recorded_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS experimental_groups (
    group_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    title TEXT NOT NULL,
    conditions_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(conditions_json))
  )''',
  '''CREATE TABLE IF NOT EXISTS samples (
    sample_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_sample_id TEXT REFERENCES samples(sample_id),
    properties_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(properties_json)),
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS run_samples (
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    sample_id TEXT NOT NULL REFERENCES samples(sample_id),
    group_id TEXT REFERENCES experimental_groups(group_id),
    PRIMARY KEY(run_id,sample_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS treatments (
    treatment_id TEXT PRIMARY KEY,
    sample_id TEXT NOT NULL REFERENCES samples(sample_id),
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    conditions_json TEXT NOT NULL CHECK(json_valid(conditions_json)),
    applied_at_utc TEXT,
    corrected_from TEXT REFERENCES treatments(treatment_id),
    recorded_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS blob_objects (
    sha256 TEXT PRIMARY KEY CHECK(length(sha256)=64),
    byte_size INTEGER NOT NULL CHECK(byte_size>=0),
    relative_path TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK(state IN('staged','committed','missing','mismatch','purged')),
    imported_at_utc TEXT NOT NULL,
    last_full_verified_at TEXT,
    last_fast_checked_at TEXT,
    last_known_size INTEGER,
    last_known_mtime_ns INTEGER,
    last_file_id TEXT,
    threshold_at_import INTEGER NOT NULL DEFAULT 2147483648
  )''',
  '''CREATE TABLE IF NOT EXISTS assets (
    asset_id TEXT PRIMARY KEY,
    blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
    display_name TEXT NOT NULL,
    media_type TEXT,
    kind TEXT NOT NULL CHECK(kind IN('raw','derived','report','thumbnail','export')),
    parent_asset_id TEXT REFERENCES assets(asset_id),
    created_at_utc TEXT NOT NULL,
    deleted_at_utc TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json))
  )''',
  '''CREATE TABLE IF NOT EXISTS asset_links (
    link_id TEXT PRIMARY KEY,
    asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    entity_type TEXT NOT NULL
      CHECK(entity_type IN('run','step','sample','measurement','calculation','analysis')),
    entity_id TEXT NOT NULL,
    relation TEXT NOT NULL,
    removed_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS deletion_records (
    deletion_id TEXT PRIMARY KEY,
    asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    scope TEXT NOT NULL CHECK(scope IN('unlink','trash','purge')),
    impact_json TEXT NOT NULL CHECK(json_valid(impact_json)),
    state TEXT NOT NULL
      CHECK(state IN('requested','trashed','purged','recovered','blocked')),
    created_at_utc TEXT NOT NULL,
    purge_eligible_at_utc TEXT,
    reason TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS integrity_checks (
    check_id TEXT PRIMARY KEY,
    blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
    mode TEXT NOT NULL CHECK(mode IN('full_sha256','metadata_quick','transfer_checksum')),
    status TEXT NOT NULL CHECK(status IN('passed','failed','unknown')),
    started_at_utc TEXT NOT NULL,
    finished_at_utc TEXT,
    details_json TEXT NOT NULL CHECK(json_valid(details_json))
  )''',
  '''CREATE TABLE IF NOT EXISTS measurements (
    measurement_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    step_id TEXT REFERENCES step_executions(step_id),
    sample_id TEXT REFERENCES samples(sample_id),
    analyte TEXT NOT NULL,
    value_text TEXT NOT NULL,
    unit TEXT,
    raw_asset_id TEXT REFERENCES assets(asset_id),
    state TEXT NOT NULL
      CHECK(state IN('draft_ai','recorded','user_confirmed','superseded')),
    superseded_by TEXT REFERENCES measurements(measurement_id),
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS calculation_packs (
    pack_id TEXT NOT NULL,
    version TEXT NOT NULL,
    manifest_sha256 TEXT NOT NULL,
    pipeline_json TEXT NOT NULL CHECK(json_valid(pipeline_json)),
    status TEXT NOT NULL CHECK(status IN('draft','validated','tested','approved','disabled')),
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(pack_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS calculation_runs (
    calculation_id TEXT PRIMARY KEY,
    run_id TEXT REFERENCES experiment_runs(run_id),
    step_id TEXT REFERENCES step_executions(step_id),
    pack_id TEXT NOT NULL,
    pack_version TEXT NOT NULL,
    input_json TEXT NOT NULL CHECK(json_valid(input_json)),
    status TEXT NOT NULL
      CHECK(status IN('queued','preparing','running','completed','failed','cancelled','interrupted')),
    trace_json TEXT CHECK(trace_json IS NULL OR json_valid(trace_json)),
    result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
    result_asset_id TEXT REFERENCES assets(asset_id),
    started_at_utc TEXT,
    finished_at_utc TEXT,
    FOREIGN KEY(pack_id,pack_version) REFERENCES calculation_packs(pack_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS analysis_runs (
    analysis_id TEXT PRIMARY KEY,
    source_asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    run_id TEXT REFERENCES experiment_runs(run_id),
    model_job_id TEXT,
    roi_approval_json TEXT CHECK(roi_approval_json IS NULL OR json_valid(roi_approval_json)),
    calculation_id TEXT REFERENCES calculation_runs(calculation_id),
    status TEXT NOT NULL,
    approved_at_utc TEXT,
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS ai_jobs (
    ai_job_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    model_id TEXT NOT NULL,
    api_mode TEXT NOT NULL CHECK(api_mode IN('responses','chat_completions')),
    skill_id TEXT,
    skill_version TEXT,
    state TEXT NOT NULL,
    request_meta_json TEXT NOT NULL CHECK(json_valid(request_meta_json)),
    response_json TEXT CHECK(response_json IS NULL OR json_valid(response_json)),
    consent_ref TEXT,
    created_at_utc TEXT NOT NULL,
    finished_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS tool_invocations (
    tool_call_id TEXT PRIMARY KEY,
    ai_job_id TEXT NOT NULL REFERENCES ai_jobs(ai_job_id),
    tool_id TEXT NOT NULL,
    params_json TEXT NOT NULL CHECK(json_valid(params_json)),
    output_json TEXT CHECK(output_json IS NULL OR json_valid(output_json)),
    state TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS installed_packs (
    pack_id TEXT NOT NULL,
    version TEXT NOT NULL,
    pack_kind TEXT NOT NULL,
    manifest_hash TEXT NOT NULL,
    approved_at_utc TEXT,
    state TEXT NOT NULL,
    PRIMARY KEY(pack_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS installed_skills (
    skill_id TEXT NOT NULL,
    version TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(skill_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS local_tasks (
    task_id TEXT PRIMARY KEY,
    step_id TEXT REFERENCES step_executions(step_id),
    title TEXT NOT NULL,
    due_at_utc TEXT,
    state TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1
  )''',
  '''CREATE TABLE IF NOT EXISTS reminders (
    reminder_id TEXT PRIMARY KEY,
    task_id TEXT REFERENCES local_tasks(task_id),
    step_id TEXT REFERENCES step_executions(step_id),
    due_at_utc TEXT NOT NULL,
    device_notification_id TEXT,
    status TEXT NOT NULL,
    last_attempt_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS todo_links (
    task_id TEXT PRIMARY KEY REFERENCES local_tasks(task_id),
    ms_list_id TEXT,
    ms_task_id TEXT,
    ms_etag TEXT,
    status TEXT NOT NULL,
    updated_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS mutation_events (
    event_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    seq INTEGER NOT NULL,
    lamport INTEGER NOT NULL,
    entity_kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    base_revision INTEGER,
    action TEXT NOT NULL,
    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
    created_at_utc TEXT NOT NULL,
    UNIQUE(device_id,seq)
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_conflicts (
    conflict_id TEXT PRIMARY KEY,
    entity_kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    event_id_a TEXT NOT NULL,
    event_id_b TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN('open','resolved')),
    resolution_event_id TEXT,
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_targets (
    target_id TEXT PRIMARY KEY,
    provider TEXT NOT NULL CHECK(provider IN('onedrive','s3')),
    policy_json TEXT NOT NULL CHECK(json_valid(policy_json)),
    secret_ref TEXT,
    epoch INTEGER NOT NULL DEFAULT 1,
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_replicas (
    replica_id TEXT PRIMARY KEY,
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
    remote_object_key TEXT NOT NULL,
    encryption_mode TEXT NOT NULL,
    last_transfer_checksum TEXT,
    state TEXT NOT NULL,
    verified_at_utc TEXT,
    UNIQUE(target_id,blob_sha256,remote_object_key)
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_cursors (
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    device_id TEXT NOT NULL,
    received_seq INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(target_id,device_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS backup_snapshots (
    backup_id TEXT PRIMARY KEY,
    target_id TEXT REFERENCES remote_targets(target_id),
    state TEXT NOT NULL,
    manifest_sha256 TEXT NOT NULL,
    encryption_mode TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    last_restored_test_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS outbox (
    outbox_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
    idempotency_key TEXT NOT NULL UNIQUE,
    next_attempt_at_utc TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN('pending','in_progress','sent','failed')),
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
  )''',
  'CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status,due_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_asset_deleted ON assets(deleted_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(state,next_attempt_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_run_steps ON step_executions(run_id,state)',
  'CREATE INDEX IF NOT EXISTS idx_mutation_events_device_seq ON mutation_events(device_id,seq)',
  '''CREATE TRIGGER IF NOT EXISTS trig_committed_blob_immutable
    BEFORE UPDATE OF sha256,byte_size,relative_path ON blob_objects
    WHEN OLD.state='committed'
    BEGIN SELECT RAISE(ABORT,'committed blob identity/contents are immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_asset_blob_immutable
    BEFORE UPDATE OF blob_sha256 ON assets
    BEGIN SELECT RAISE(ABORT,'cannot replace content of an Asset; create a new Asset'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_protocol_approved_immutable
    BEFORE UPDATE ON protocol_versions
    WHEN OLD.approved_at_utc IS NOT NULL
    BEGIN SELECT RAISE(ABORT,'approved ProtocolVersion cannot be modified; create a new version'); END''',
];

const List<String> schemaV2Statements = [
  // Immutable protocol snapshots, run plan snapshots, and explicit timing data.
  '''ALTER TABLE protocols ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE protocol_versions ADD COLUMN approval_ref TEXT''',
  '''ALTER TABLE protocol_versions ADD COLUMN validation_report_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(validation_report_json))''',
  '''ALTER TABLE protocol_versions ADD COLUMN provenance_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(provenance_json))''',
  '''ALTER TABLE experiment_runs ADD COLUMN protocol_snapshot_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(protocol_snapshot_json))''',
  '''ALTER TABLE experiment_runs ADD COLUMN planned_start_utc TEXT''',
  '''ALTER TABLE step_executions ADD COLUMN planned_end_utc TEXT''',
  '''ALTER TABLE step_executions ADD COLUMN duration_min_seconds INTEGER''',
  '''ALTER TABLE step_executions ADD COLUMN duration_max_seconds INTEGER''',
  '''ALTER TABLE step_executions ADD COLUMN duration_origin TEXT
    NOT NULL DEFAULT 'unknown'
    CHECK(duration_origin IN('user','sop','historical','ai_estimate','unknown'))''',
  '''ALTER TABLE step_executions ADD COLUMN instructions TEXT NOT NULL DEFAULT '' ''',
  '''ALTER TABLE step_executions ADD COLUMN parameters_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(parameters_json))''',
  '''ALTER TABLE step_executions ADD COLUMN human_gate INTEGER NOT NULL DEFAULT 0
    CHECK(human_gate IN(0,1))''',
  '''ALTER TABLE step_executions ADD COLUMN repeat_index INTEGER NOT NULL DEFAULT 0
    CHECK(repeat_index >= 0)''',
  '''ALTER TABLE step_executions ADD COLUMN resource_key TEXT''',
  '''ALTER TABLE experimental_groups ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE run_samples ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE samples ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE samples ADD COLUMN deleted_at_utc TEXT''',
  '''ALTER TABLE treatments ADD COLUMN correction_reason TEXT''',
  '''ALTER TABLE measurements ADD COLUMN source_method TEXT''',
  '''ALTER TABLE measurements ADD COLUMN source_ref TEXT''',
  '''ALTER TABLE measurements ADD COLUMN confirmed_at_utc TEXT''',
  '''ALTER TABLE measurements ADD COLUMN confirmed_by TEXT''',
  '''ALTER TABLE measurements ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE measurements ADD COLUMN calculation_id TEXT
    REFERENCES calculation_runs(calculation_id)''',
  '''ALTER TABLE measurements ADD COLUMN remote_calculation_output_key TEXT''',
  '''ALTER TABLE measurements ADD COLUMN remote_source_event_id TEXT
    REFERENCES remote_measurement_imports(source_event_id)''',
  '''ALTER TABLE measurements ADD COLUMN remote_measurement_id TEXT''',
  '''ALTER TABLE measurements ADD COLUMN remote_calculation_id TEXT
    REFERENCES remote_calculation_run_imports(calculation_id)
    CHECK(remote_calculation_id IS NULL OR
      (remote_calculation_output_key IS NOT NULL AND remote_source_event_id IS NOT NULL AND remote_measurement_id IS NOT NULL))''',
  '''ALTER TABLE analysis_runs ADD COLUMN calculation_trace_id TEXT''',
  '''ALTER TABLE step_events ADD COLUMN command_id TEXT''',
  '''ALTER TABLE step_events ADD COLUMN correction_of_event_id TEXT
    REFERENCES step_events(event_id)''',
  '''ALTER TABLE reminders ADD COLUMN minutes_before INTEGER NOT NULL DEFAULT 0
    CHECK(minutes_before >= 0)''',
  '''ALTER TABLE reminders ADD COLUMN permission_state TEXT''',
  '''ALTER TABLE reminders ADD COLUMN delivery_state TEXT NOT NULL DEFAULT 'pending'
    CHECK(delivery_state IN('pending','scheduled','delivered','denied','failed','cancelled'))''',
  '''ALTER TABLE reminders ADD COLUMN command_id TEXT''',
  '''ALTER TABLE reminders ADD COLUMN updated_at_utc TEXT''',
  '''ALTER TABLE local_tasks ADD COLUMN created_at_utc TEXT NOT NULL DEFAULT '' ''',
  '''ALTER TABLE local_tasks ADD COLUMN completed_at_utc TEXT''',
  '''ALTER TABLE local_tasks ADD COLUMN command_id TEXT''',
  '''ALTER TABLE local_tasks ADD COLUMN deleted_at_utc TEXT''',
  '''ALTER TABLE todo_links ADD COLUMN local_revision INTEGER NOT NULL DEFAULT 0''',
  '''ALTER TABLE todo_links ADD COLUMN ms_account_id TEXT''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS idx_local_task_command
    ON local_tasks(command_id) WHERE command_id IS NOT NULL''',

  // Command idempotency and append-only local event/outbox log.
  '''ALTER TABLE mutation_events ADD COLUMN command_id TEXT''',
  '''ALTER TABLE mutation_events ADD COLUMN event_type TEXT NOT NULL DEFAULT 'mutation.legacy' ''',
  '''ALTER TABLE mutation_events ADD COLUMN asset_sha_refs_json TEXT
    NOT NULL DEFAULT '[]' CHECK(json_valid(asset_sha_refs_json))''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS idx_mutation_command_id
    ON mutation_events(command_id) WHERE command_id IS NOT NULL''',

  // Calculation output/trace snapshots; approved packs remain versioned.
  '''ALTER TABLE calculation_packs ADD COLUMN manifest_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(manifest_json))''',
  '''ALTER TABLE calculation_packs ADD COLUMN forms_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(forms_json))''',
  '''ALTER TABLE calculation_packs ADD COLUMN origin TEXT NOT NULL DEFAULT 'local' ''',
  '''ALTER TABLE calculation_packs ADD COLUMN trust_level TEXT NOT NULL DEFAULT 'unreviewed' ''',
  '''ALTER TABLE calculation_packs ADD COLUMN approval_ref_json TEXT
    CHECK(approval_ref_json IS NULL OR json_valid(approval_ref_json))''',
  '''ALTER TABLE calculation_packs ADD COLUMN approved_at_utc TEXT''',
  '''ALTER TABLE calculation_packs ADD COLUMN installed_at_utc TEXT''',
  '''ALTER TABLE calculation_packs ADD COLUMN signature TEXT''',
  '''ALTER TABLE calculation_packs ADD COLUMN engine_compatibility TEXT
    NOT NULL DEFAULT '{}' ''',
  '''ALTER TABLE calculation_runs ADD COLUMN parent_calculation_id TEXT
    REFERENCES calculation_runs(calculation_id)''',
  '''ALTER TABLE calculation_runs ADD COLUMN sample_id TEXT REFERENCES samples(sample_id)''',
  '''ALTER TABLE calculation_runs ADD COLUMN pack_sha256 TEXT''',
  '''ALTER TABLE calculation_runs ADD COLUMN source_assets_json TEXT
    NOT NULL DEFAULT '[]' CHECK(json_valid(source_assets_json))''',
  '''ALTER TABLE calculation_runs ADD COLUMN output_json TEXT
    CHECK(output_json IS NULL OR json_valid(output_json))''',
  '''ALTER TABLE calculation_runs ADD COLUMN trace_sha256 TEXT''',
  '''ALTER TABLE calculation_runs ADD COLUMN error_code TEXT''',
  '''ALTER TABLE calculation_runs ADD COLUMN completed_at_utc TEXT''',
  '''ALTER TABLE calculation_runs ADD COLUMN revision INTEGER NOT NULL DEFAULT 1''',

  // Asset integrity, recoverable import staging, references, and garbage collection.
  '''ALTER TABLE blob_objects ADD COLUMN staging_path TEXT''',
  '''ALTER TABLE blob_objects ADD COLUMN integrity_policy_snapshot TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(integrity_policy_snapshot))''',
  '''ALTER TABLE assets ADD COLUMN origin TEXT NOT NULL DEFAULT 'managed_import' ''',
  '''ALTER TABLE assets ADD COLUMN external_reference TEXT''',
  '''ALTER TABLE asset_links ADD COLUMN created_at_utc TEXT''',
  '''ALTER TABLE asset_links ADD COLUMN metadata_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(metadata_json))''',
  '''ALTER TABLE deletion_records ADD COLUMN approval_ref TEXT''',
  '''ALTER TABLE deletion_records ADD COLUMN confirmed_at_utc TEXT''',
  '''ALTER TABLE deletion_records ADD COLUMN command_id TEXT''',
  '''ALTER TABLE integrity_checks ADD COLUMN verification_level TEXT''',
  '''CREATE TABLE IF NOT EXISTS pending_asset_imports (
    import_id TEXT PRIMARY KEY,
    blob_sha256 TEXT NOT NULL,
    staging_relative_path TEXT NOT NULL,
    asset_id TEXT NOT NULL,
    asset_json TEXT NOT NULL CHECK(json_valid(asset_json)),
    link_refs_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(link_refs_json)),
    command_id TEXT NOT NULL UNIQUE,
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS asset_blob_leases (
    lease_id TEXT PRIMARY KEY,
    blob_sha256 TEXT NOT NULL REFERENCES blob_objects(sha256),
    owner TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    expires_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS pending_sync_blobs (
    sha256 TEXT PRIMARY KEY REFERENCES blob_objects(sha256),
    source_target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    staging_relative_path TEXT NOT NULL,
    byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
    created_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_received_blobs (
    sha256 TEXT PRIMARY KEY REFERENCES blob_objects(sha256),
    source_target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    received_at_utc TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN('available','released'))
  )''',
  '''CREATE INDEX IF NOT EXISTS idx_asset_blob_leases_expiry
    ON asset_blob_leases(blob_sha256,expires_at_utc)''',
  '''CREATE TABLE IF NOT EXISTS asset_blob_gc_claims (
    blob_sha256 TEXT PRIMARY KEY REFERENCES blob_objects(sha256),
    claim_id TEXT NOT NULL UNIQUE,
    claimed_at_utc TEXT NOT NULL,
    operation TEXT NOT NULL DEFAULT 'gc' CHECK(operation IN('gc','purge')),
    deletion_id TEXT REFERENCES deletion_records(deletion_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS asset_sync_tombstone_acks (
    asset_id TEXT NOT NULL,
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    created_at_utc TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN('pending','acknowledged','failed')),
    acknowledged_at_utc TEXT,
    PRIMARY KEY(asset_id,target_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS asset_virtual_folders (
    folder_id TEXT PRIMARY KEY,
    parent_folder_id TEXT REFERENCES asset_virtual_folders(folder_id),
    name TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(parent_folder_id,name)
  )''',
  '''CREATE TABLE IF NOT EXISTS asset_folder_memberships (
    folder_id TEXT NOT NULL REFERENCES asset_virtual_folders(folder_id),
    asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(folder_id,asset_id)
  )''',

  // Remote object metadata supports optional encryption and truthful verification.
  '''ALTER TABLE remote_targets ADD COLUMN display_name TEXT NOT NULL DEFAULT '' ''',
  '''ALTER TABLE remote_targets ADD COLUMN updated_at_utc TEXT''',
  '''ALTER TABLE remote_targets ADD COLUMN last_verified_at_utc TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN content_sha256 TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN key_id TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN format_version TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN source_asset_id TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN byte_size INTEGER''',
  '''ALTER TABLE remote_replicas ADD COLUMN verification_level TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN updated_at_utc TEXT''',
  '''ALTER TABLE remote_replicas ADD COLUMN policy_epoch INTEGER NOT NULL DEFAULT 1''',
  '''CREATE TABLE IF NOT EXISTS remote_target_epochs (
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    epoch INTEGER NOT NULL CHECK(epoch > 0),
    policy_json TEXT NOT NULL CHECK(json_valid(policy_json)),
    secret_ref TEXT,
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(target_id,epoch)
  )''',
  '''INSERT OR IGNORE INTO remote_target_epochs(target_id,epoch,policy_json,secret_ref,created_at_utc)
    SELECT target_id,epoch,policy_json,secret_ref,created_at_utc FROM remote_targets''',
  '''CREATE TABLE IF NOT EXISTS sync_epoch_migrations (
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    source_epoch INTEGER NOT NULL,
    destination_epoch INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN('pending','running','completed','failed')),
    source_event_count INTEGER NOT NULL DEFAULT 0 CHECK(source_event_count >= 0),
    verified_event_count INTEGER NOT NULL DEFAULT 0 CHECK(verified_event_count >= 0),
    source_blob_count INTEGER NOT NULL DEFAULT 0 CHECK(source_blob_count >= 0),
    verified_blob_count INTEGER NOT NULL DEFAULT 0 CHECK(verified_blob_count >= 0),
    last_error TEXT,
    started_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    completed_at_utc TEXT,
    PRIMARY KEY(target_id,source_epoch,destination_epoch),
    FOREIGN KEY(target_id,source_epoch) REFERENCES remote_target_epochs(target_id,epoch),
    FOREIGN KEY(target_id,destination_epoch) REFERENCES remote_target_epochs(target_id,epoch),
    CHECK(source_epoch <> destination_epoch),
    CHECK(verified_event_count <= source_event_count),
    CHECK(verified_blob_count <= source_blob_count)
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_epoch_migration_items (
    target_id TEXT NOT NULL,
    source_epoch INTEGER NOT NULL,
    destination_epoch INTEGER NOT NULL,
    item_kind TEXT NOT NULL CHECK(item_kind IN('event','blob')),
    item_id TEXT NOT NULL,
    source_sha256 TEXT,
    destination_sha256 TEXT,
    state TEXT NOT NULL CHECK(state IN('pending','copied','verified','failed')),
    last_error TEXT,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY(target_id,source_epoch,destination_epoch,item_kind,item_id),
    FOREIGN KEY(target_id,source_epoch,destination_epoch)
      REFERENCES sync_epoch_migrations(target_id,source_epoch,destination_epoch),
    CHECK(source_epoch <> destination_epoch),
    CHECK(state <> 'verified' OR
      (source_sha256 IS NOT NULL AND destination_sha256 IS NOT NULL AND source_sha256=destination_sha256))
  )''',
  '''ALTER TABLE backup_snapshots ADD COLUMN db_schema_version INTEGER''',
  '''ALTER TABLE backup_snapshots ADD COLUMN vault_id TEXT''',
  '''ALTER TABLE backup_snapshots ADD COLUMN target_epoch INTEGER''',
  '''UPDATE backup_snapshots SET target_epoch=(SELECT epoch FROM remote_targets WHERE remote_targets.target_id=backup_snapshots.target_id)
    WHERE target_id IS NOT NULL AND target_epoch IS NULL''',
  '''ALTER TABLE backup_snapshots ADD COLUMN sqlite_snapshot_path TEXT''',
  '''ALTER TABLE backup_snapshots ADD COLUMN asset_manifest_json TEXT
    NOT NULL DEFAULT '[]' CHECK(json_valid(asset_manifest_json))''',
  '''ALTER TABLE backup_snapshots ADD COLUMN encryption_policy_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(encryption_policy_json))''',
  '''ALTER TABLE backup_snapshots ADD COLUMN checksum_policy_json TEXT
    NOT NULL DEFAULT '{}' CHECK(json_valid(checksum_policy_json))''',
  '''ALTER TABLE backup_snapshots ADD COLUMN pack_versions_json TEXT
    NOT NULL DEFAULT '[]' CHECK(json_valid(pack_versions_json))''',
  '''CREATE TABLE IF NOT EXISTS backup_snapshot_objects (
    backup_id TEXT NOT NULL REFERENCES backup_snapshots(backup_id),
    object_id TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    remote_key TEXT,
    byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
    encryption_mode TEXT NOT NULL,
    key_id TEXT,
    verification_level TEXT NOT NULL,
    PRIMARY KEY(backup_id,object_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS backup_restore_reports (
    restore_id TEXT PRIMARY KEY,
    backup_id TEXT NOT NULL REFERENCES backup_snapshots(backup_id),
    state TEXT NOT NULL,
    report_json TEXT NOT NULL CHECK(json_valid(report_json)),
    tested_at_utc TEXT NOT NULL
  )''',

  // Versioned settings, user approvals, provider consent, and immutable ROI review.
  '''CREATE TABLE IF NOT EXISTS workspace_settings (
    setting_key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL CHECK(json_valid(value_json)),
    revision INTEGER NOT NULL DEFAULT 1,
    updated_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS approval_receipts (
    approval_ref TEXT PRIMARY KEY,
    action TEXT NOT NULL,
    subject_type TEXT NOT NULL,
    subject_id TEXT NOT NULL,
    scope_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(scope_json)),
    approved_at_utc TEXT NOT NULL,
    expires_at_utc TEXT,
    revoked_at_utc TEXT,
    command_id TEXT NOT NULL UNIQUE
  )''',
  '''CREATE TABLE IF NOT EXISTS ai_provider_profiles (
    provider_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    base_url TEXT NOT NULL,
    api_mode TEXT NOT NULL CHECK(api_mode IN('responses','chat_completions')),
    model_id TEXT NOT NULL,
    secret_ref TEXT,
    capabilities_json TEXT NOT NULL CHECK(json_valid(capabilities_json)),
    budgets_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(budgets_json)),
    timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds > 0),
    data_policy_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(data_policy_json)),
    enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN(0,1)),
    revision INTEGER NOT NULL DEFAULT 1,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS ai_consent_receipts (
    consent_id TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL REFERENCES ai_provider_profiles(provider_id),
    purpose TEXT NOT NULL,
    data_class TEXT NOT NULL,
    asset_ids_json TEXT NOT NULL CHECK(json_valid(asset_ids_json)),
    total_bytes INTEGER NOT NULL CHECK(total_bytes >= 0),
    estimated_cost_text TEXT,
    approved_scopes_json TEXT NOT NULL CHECK(json_valid(approved_scopes_json)),
    approved_at_utc TEXT NOT NULL,
    expires_at_utc TEXT,
    revoked_at_utc TEXT,
    approval_ref TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS skill_registry_versions (
    skill_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    instructions_text TEXT NOT NULL,
    capabilities_json TEXT NOT NULL CHECK(json_valid(capabilities_json)),
    permission_level TEXT NOT NULL CHECK(permission_level='instruction_only'),
    state TEXT NOT NULL
      CHECK(state IN('draft','validated','enabled','disabled')),
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(skill_id,version)
  )''',
  '''CREATE TABLE IF NOT EXISTS ai_pack_drafts (
    draft_id TEXT PRIMARY KEY,
    ai_job_id TEXT REFERENCES ai_jobs(ai_job_id),
    pack_id TEXT NOT NULL,
    version TEXT NOT NULL,
    document_json TEXT NOT NULL CHECK(json_valid(document_json)),
    validation_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(validation_json)),
    unsupported_operations_json TEXT NOT NULL DEFAULT '[]'
      CHECK(json_valid(unsupported_operations_json)),
    requires_user_input_json TEXT NOT NULL DEFAULT '[]'
      CHECK(json_valid(requires_user_input_json)),
    state TEXT NOT NULL
      CHECK(state IN('draft','validated','review_required','approved','rejected')),
    content_sha256 TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    approved_at_utc TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS image_roi_reviews (
    review_id TEXT PRIMARY KEY,
    analysis_id TEXT NOT NULL REFERENCES analysis_runs(analysis_id),
    original_asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    source_sha256 TEXT NOT NULL,
    validation_level TEXT NOT NULL CHECK(validation_level IN('verified','quick_checked')),
    candidate_rois_json TEXT NOT NULL CHECK(json_valid(candidate_rois_json)),
    approved_rois_json TEXT CHECK(approved_rois_json IS NULL OR json_valid(approved_rois_json)),
    approval_ref TEXT,
    approved_at_utc TEXT,
    quantification_trace_id TEXT,
    trace_asset_id TEXT REFERENCES assets(asset_id),
    derived_asset_ids_json TEXT NOT NULL DEFAULT '[]'
      CHECK(json_valid(derived_asset_ids_json)),
    state TEXT NOT NULL
      CHECK(state IN('proposed','approved','executed','rejected'))
  )''',
  '''CREATE TABLE IF NOT EXISTS todo_integration_state (
    integration_id TEXT PRIMARY KEY,
    primary_device_id TEXT NOT NULL REFERENCES devices(device_id),
    profile_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(profile_json)),
    secret_ref TEXT,
    updated_at_utc TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    takeover_approval_ref TEXT,
    delta_cursor TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS todo_import_conflicts (
    conflict_id TEXT PRIMARY KEY,
    integration_id TEXT NOT NULL REFERENCES todo_integration_state(integration_id),
    account_scope_id TEXT NOT NULL,
    task_id TEXT REFERENCES local_tasks(task_id),
    ms_list_id TEXT,
    ms_task_id TEXT NOT NULL,
    local_snapshot_json TEXT NOT NULL CHECK(json_valid(local_snapshot_json)),
    remote_snapshot_json TEXT NOT NULL CHECK(json_valid(remote_snapshot_json)),
    local_revision INTEGER,
    remote_etag TEXT,
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE
  )''',
  '''CREATE TABLE IF NOT EXISTS todo_conflict_resolutions (
    resolution_id TEXT PRIMARY KEY,
    conflict_id TEXT NOT NULL UNIQUE REFERENCES todo_import_conflicts(conflict_id),
    decision TEXT NOT NULL CHECK(decision IN('keep_local','accept_remote','ignore_remote')),
    selected_snapshot_json TEXT CHECK(selected_snapshot_json IS NULL OR json_valid(selected_snapshot_json)),
    expected_local_revision INTEGER,
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_remote_events (
    event_id TEXT PRIMARY KEY,
    command_id TEXT NOT NULL UNIQUE,
    device_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    lamport INTEGER NOT NULL,
    entity_kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    base_revision INTEGER,
    event_type TEXT NOT NULL,
    action TEXT NOT NULL,
    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
    wire_json TEXT CHECK(wire_json IS NULL OR json_valid(wire_json)),
    asset_sha_refs_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(asset_sha_refs_json)),
    created_at_utc TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    source_target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    application_state TEXT NOT NULL DEFAULT 'received'
      CHECK(application_state IN('received','applied','conflicted','blocked')),
    application_error TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_remote_event_targets (
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    event_id TEXT NOT NULL REFERENCES sync_remote_events(event_id),
    received_at_utc TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN('received','applied','conflicted','blocked')),
    PRIMARY KEY(target_id,event_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_calculation_pack_drafts (
    source_event_id TEXT PRIMARY KEY REFERENCES sync_remote_events(event_id),
    pack_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_sha256 TEXT NOT NULL CHECK(length(content_sha256)=64),
    document_json TEXT NOT NULL CHECK(json_valid(document_json)),
    source_device_id TEXT NOT NULL,
    source_approval_ref TEXT,
    source_signature TEXT,
    source_provenance_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(source_provenance_json)),
    imported_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_calculation_run_imports (
    source_event_id TEXT PRIMARY KEY REFERENCES sync_remote_events(event_id),
    calculation_id TEXT NOT NULL UNIQUE,
    parent_calculation_id TEXT,
    run_id TEXT,
    sample_id TEXT,
    step_id TEXT,
    pack_id TEXT NOT NULL,
    pack_version TEXT NOT NULL,
    pack_sha256 TEXT NOT NULL CHECK(length(pack_sha256)=64),
    input_json TEXT NOT NULL CHECK(json_valid(input_json)),
    source_assets_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(source_assets_json)),
    status TEXT NOT NULL CHECK(status IN('completed','failed')),
    output_json TEXT CHECK(output_json IS NULL OR json_valid(output_json)),
    trace_json TEXT CHECK(trace_json IS NULL OR json_valid(trace_json)),
    trace_sha256 TEXT CHECK(trace_sha256 IS NULL OR length(trace_sha256)=64),
    error_code TEXT,
    pack_snapshot_json TEXT NOT NULL CHECK(json_valid(pack_snapshot_json)),
    source_provenance_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(source_provenance_json)),
    source_device_id TEXT NOT NULL,
    imported_at_utc TEXT NOT NULL,
    CHECK((status='completed' AND output_json IS NOT NULL AND trace_json IS NOT NULL AND trace_sha256 IS NOT NULL)
       OR (status='failed' AND error_code IS NOT NULL AND length(trim(error_code))>0))
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_measurement_imports (
    source_event_id TEXT PRIMARY KEY REFERENCES sync_remote_events(event_id),
    remote_measurement_id TEXT NOT NULL,
    source_event_type TEXT NOT NULL CHECK(source_event_type IN('measurement.recorded','measurement.corrected')),
    original_remote_measurement_id TEXT,
    source_device_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    step_id TEXT,
    sample_id TEXT,
    analyte TEXT NOT NULL,
    value_text TEXT NOT NULL,
    unit TEXT,
    raw_asset_id TEXT,
    calculation_id TEXT NOT NULL REFERENCES remote_calculation_run_imports(calculation_id),
    calculation_trace_sha256 TEXT NOT NULL CHECK(length(calculation_trace_sha256)=64),
    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
    asset_sha_refs_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(asset_sha_refs_json)),
    imported_at_utc TEXT NOT NULL,
    CHECK((source_event_type='measurement.recorded' AND original_remote_measurement_id IS NULL) OR
          (source_event_type='measurement.corrected' AND original_remote_measurement_id IS NOT NULL))
  )''',
  '''CREATE TABLE IF NOT EXISTS remote_measurement_reviews (
    review_id TEXT PRIMARY KEY,
    source_event_id TEXT NOT NULL REFERENCES remote_measurement_imports(source_event_id),
    reviewer_device_id TEXT NOT NULL REFERENCES devices(device_id),
    action TEXT NOT NULL CHECK(action IN('imported','rejected')),
    approval_ref TEXT REFERENCES approval_receipts(approval_ref),
    local_measurement_id TEXT REFERENCES measurements(measurement_id),
    reason TEXT,
    command_id TEXT NOT NULL UNIQUE,
    created_at_utc TEXT NOT NULL,
    UNIQUE(source_event_id,reviewer_device_id),
    CHECK((action='imported' AND approval_ref IS NOT NULL AND local_measurement_id IS NOT NULL AND reason IS NULL) OR
          (action='rejected' AND local_measurement_id IS NULL AND reason IS NOT NULL AND length(trim(reason))>0))
  )''',
  '''CREATE TABLE IF NOT EXISTS community_pack_publishers (
    publisher_id TEXT PRIMARY KEY,
    public_key_base64 TEXT NOT NULL,
    key_fingerprint TEXT NOT NULL UNIQUE,
    trusted_at_utc TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN(0,1)),
    revision INTEGER NOT NULL DEFAULT 1,
    updated_at_utc TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_outbox_targets (
    target_id TEXT NOT NULL REFERENCES remote_targets(target_id),
    event_id TEXT NOT NULL REFERENCES outbox(outbox_id),
    state TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_utc TEXT NOT NULL,
    last_error TEXT,
    remote_key TEXT,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY(target_id,event_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS sample_edges (
    edge_id TEXT PRIMARY KEY,
    parent_sample_id TEXT NOT NULL REFERENCES samples(sample_id),
    child_sample_id TEXT NOT NULL REFERENCES samples(sample_id),
    relationship_kind TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE,
    CHECK(parent_sample_id <> child_sample_id),
    UNIQUE(parent_sample_id,child_sample_id,relationship_kind)
  )''',
  '''CREATE TABLE IF NOT EXISTS treatment_corrections (
    correction_id TEXT PRIMARY KEY,
    treatment_id TEXT NOT NULL REFERENCES treatments(treatment_id),
    replacement_treatment_id TEXT NOT NULL REFERENCES treatments(treatment_id),
    reason TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE
  )''',
  '''CREATE TABLE IF NOT EXISTS measurement_corrections (
    correction_id TEXT PRIMARY KEY,
    measurement_id TEXT NOT NULL REFERENCES measurements(measurement_id),
    replacement_measurement_id TEXT NOT NULL UNIQUE REFERENCES measurements(measurement_id),
    reason TEXT NOT NULL CHECK(length(trim(reason)) > 0),
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE,
    CHECK(measurement_id <> replacement_measurement_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS schedule_traces (
    trace_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES experiment_runs(run_id),
    generation INTEGER NOT NULL,
    input_json TEXT NOT NULL CHECK(json_valid(input_json)),
    schedule_json TEXT NOT NULL CHECK(json_valid(schedule_json)),
    warnings_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(warnings_json)),
    created_at_utc TEXT NOT NULL,
    command_id TEXT NOT NULL UNIQUE
  )''',
  '''CREATE TABLE IF NOT EXISTS calculation_job_logs (
    log_id TEXT PRIMARY KEY,
    calculation_id TEXT NOT NULL REFERENCES calculation_runs(calculation_id),
    state TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
  )''',

  'CREATE INDEX IF NOT EXISTS idx_samples_parent ON samples(parent_sample_id)',
  'CREATE INDEX IF NOT EXISTS idx_treatments_sample_time ON treatments(sample_id,applied_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_protocol_versions_status ON protocol_versions(status)',
  'CREATE INDEX IF NOT EXISTS idx_runs_experiment_state ON experiment_runs(experiment_id,state)',
  'CREATE INDEX IF NOT EXISTS idx_schedule_traces_run ON schedule_traces(run_id,generation)',
  'CREATE INDEX IF NOT EXISTS idx_backup_snapshot_objects_sha ON backup_snapshot_objects(content_sha256)',
  'CREATE INDEX IF NOT EXISTS idx_ai_consent_active ON ai_consent_receipts(provider_id,revoked_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_sync_remote_entity ON sync_remote_events(entity_kind,entity_id,lamport)',
  'CREATE INDEX IF NOT EXISTS idx_sync_remote_target_event ON sync_remote_event_targets(target_id,event_id)',
  'CREATE INDEX IF NOT EXISTS idx_sync_outbox_target_state ON sync_outbox_targets(target_id,state,next_attempt_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_remote_pack_draft_identity_hash ON remote_calculation_pack_drafts(pack_id,version,content_sha256)',
  'CREATE INDEX IF NOT EXISTS idx_remote_calculation_run_context ON remote_calculation_run_imports(run_id,sample_id,calculation_id)',
  'CREATE INDEX IF NOT EXISTS idx_remote_measurement_import_context ON remote_measurement_imports(run_id,sample_id,imported_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_remote_measurement_review_state ON remote_measurement_reviews(reviewer_device_id,action,created_at_utc)',
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_measurement_remote_source_unique ON measurements(remote_source_event_id) WHERE remote_source_event_id IS NOT NULL',
  'CREATE INDEX IF NOT EXISTS idx_remote_target_epochs_created ON remote_target_epochs(target_id,created_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_sync_epoch_migrations_state ON sync_epoch_migrations(target_id,state,updated_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_sync_epoch_migration_items_state ON sync_epoch_migration_items(target_id,source_epoch,destination_epoch,state,item_kind)',
  'CREATE INDEX IF NOT EXISTS idx_todo_conflicts_remote_task ON todo_import_conflicts(integration_id,account_scope_id,ms_task_id,created_at_utc)',
  'CREATE INDEX IF NOT EXISTS idx_todo_conflict_resolutions_conflict ON todo_conflict_resolutions(conflict_id,created_at_utc)',

  '''CREATE TRIGGER IF NOT EXISTS trig_approved_protocol_delete_immutable
    BEFORE DELETE ON protocol_versions
    WHEN OLD.status='approved' OR OLD.approved_at_utc IS NOT NULL
    BEGIN SELECT RAISE(ABORT,'approved ProtocolVersion is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_approved_protocol_update_immutable
    BEFORE UPDATE ON protocol_versions
    WHEN OLD.status='approved' OR OLD.approved_at_utc IS NOT NULL
    BEGIN SELECT RAISE(ABORT,'approved ProtocolVersion is immutable; create a new version'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_mutation_events_no_update
    BEFORE UPDATE ON mutation_events
    BEGIN SELECT RAISE(ABORT,'MutationEvent is append-only'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_mutation_events_no_delete
    BEFORE DELETE ON mutation_events
    BEGIN SELECT RAISE(ABORT,'MutationEvent is append-only'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_step_events_no_update
    BEFORE UPDATE ON step_events
    BEGIN SELECT RAISE(ABORT,'StepEvent is append-only'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_step_events_no_delete
    BEFORE DELETE ON step_events
    BEGIN SELECT RAISE(ABORT,'StepEvent is append-only'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_treatment_no_update
    BEFORE UPDATE ON treatments
    BEGIN SELECT RAISE(ABORT,'TreatmentRecord is immutable; append a correction'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_treatment_no_delete
    BEFORE DELETE ON treatments
    BEGIN SELECT RAISE(ABORT,'TreatmentRecord is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_measurement_update_guard
    BEFORE UPDATE ON measurements
    WHEN OLD.state='superseded' OR
      NEW.measurement_id IS NOT OLD.measurement_id OR
      NEW.run_id IS NOT OLD.run_id OR
      NEW.step_id IS NOT OLD.step_id OR
      NEW.sample_id IS NOT OLD.sample_id OR
      NEW.analyte IS NOT OLD.analyte OR
      NEW.value_text IS NOT OLD.value_text OR
      NEW.unit IS NOT OLD.unit OR
      NEW.raw_asset_id IS NOT OLD.raw_asset_id OR
      NEW.created_at_utc IS NOT OLD.created_at_utc OR
      NEW.source_method IS NOT OLD.source_method OR
      NEW.source_ref IS NOT OLD.source_ref OR
      NEW.calculation_id IS NOT OLD.calculation_id OR
      NEW.remote_calculation_id IS NOT OLD.remote_calculation_id OR
      NEW.remote_calculation_output_key IS NOT OLD.remote_calculation_output_key OR
      NEW.remote_source_event_id IS NOT OLD.remote_source_event_id OR
      NEW.remote_measurement_id IS NOT OLD.remote_measurement_id OR
      NEW.revision <> OLD.revision + 1 OR
      NOT (
        (OLD.state IN('draft_ai','recorded') AND NEW.state='user_confirmed' AND
         OLD.superseded_by IS NULL AND NEW.superseded_by IS NULL AND
         NEW.confirmed_at_utc IS NOT NULL AND NEW.confirmed_by IS NOT NULL) OR
        (OLD.state IN('draft_ai','recorded','user_confirmed') AND NEW.state='superseded' AND
         OLD.superseded_by IS NULL AND NEW.superseded_by IS NOT NULL AND
         NEW.confirmed_at_utc IS OLD.confirmed_at_utc AND NEW.confirmed_by IS OLD.confirmed_by)
      )
    BEGIN SELECT RAISE(ABORT,'Measurement is immutable; confirm or append a correction'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_measurement_no_delete
    BEFORE DELETE ON measurements
    BEGIN SELECT RAISE(ABORT,'Measurement history is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_measurement_corrections_no_update
    BEFORE UPDATE ON measurement_corrections
    BEGIN SELECT RAISE(ABORT,'Measurement correction history is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_measurement_corrections_no_delete
    BEFORE DELETE ON measurement_corrections
    BEGIN SELECT RAISE(ABORT,'Measurement correction history is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_pack_draft_no_update
    BEFORE UPDATE ON remote_calculation_pack_drafts
    BEGIN SELECT RAISE(ABORT,'Imported CalculationPack draft is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_pack_draft_no_delete
    BEFORE DELETE ON remote_calculation_pack_drafts
    BEGIN SELECT RAISE(ABORT,'Imported CalculationPack draft is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_calculation_run_no_update
    BEFORE UPDATE ON remote_calculation_run_imports
    BEGIN SELECT RAISE(ABORT,'Imported CalculationRun is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_calculation_run_no_delete
    BEFORE DELETE ON remote_calculation_run_imports
    BEGIN SELECT RAISE(ABORT,'Imported CalculationRun is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_measurement_import_no_update
    BEFORE UPDATE ON remote_measurement_imports
    BEGIN SELECT RAISE(ABORT,'Imported Measurement is immutable; append a review'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_measurement_import_no_delete
    BEFORE DELETE ON remote_measurement_imports
    BEGIN SELECT RAISE(ABORT,'Imported Measurement is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_measurement_review_no_update
    BEFORE UPDATE ON remote_measurement_reviews
    BEGIN SELECT RAISE(ABORT,'Measurement review decision is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_measurement_review_no_delete
    BEFORE DELETE ON remote_measurement_reviews
    BEGIN SELECT RAISE(ABORT,'Measurement review decision is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_target_epochs_no_update
    BEFORE UPDATE ON remote_target_epochs
    BEGIN SELECT RAISE(ABORT,'Remote target epochs are immutable; create a new epoch'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_target_epochs_no_delete
    BEFORE DELETE ON remote_target_epochs
    BEGIN SELECT RAISE(ABORT,'Remote target epochs are retained for recovery'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_todo_import_conflicts_no_update
    BEFORE UPDATE ON todo_import_conflicts
    BEGIN SELECT RAISE(ABORT,'To Do conflict snapshots are immutable; append a resolution'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_todo_import_conflicts_no_delete
    BEFORE DELETE ON todo_import_conflicts
    BEGIN SELECT RAISE(ABORT,'To Do conflict snapshots are retained for audit'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_todo_conflict_resolutions_no_update
    BEFORE UPDATE ON todo_conflict_resolutions
    BEGIN SELECT RAISE(ABORT,'To Do conflict resolutions are immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_todo_conflict_resolutions_no_delete
    BEFORE DELETE ON todo_conflict_resolutions
    BEGIN SELECT RAISE(ABORT,'To Do conflict resolutions are retained for audit'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_schedule_trace_no_update
    BEFORE UPDATE ON schedule_traces
    BEGIN SELECT RAISE(ABORT,'ScheduleTrace is immutable; create a new generation'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_schedule_trace_no_delete
    BEFORE DELETE ON schedule_traces
    BEGIN SELECT RAISE(ABORT,'ScheduleTrace is immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_community_pack_publisher_key_immutable
    BEFORE UPDATE ON community_pack_publishers
    WHEN NEW.publisher_id IS NOT OLD.publisher_id OR
         NEW.public_key_base64 IS NOT OLD.public_key_base64 OR
         NEW.key_fingerprint IS NOT OLD.key_fingerprint OR
         NEW.trusted_at_utc IS NOT OLD.trusted_at_utc OR
         NEW.revision <> OLD.revision + 1
    BEGIN SELECT RAISE(ABORT,'Pinned community publisher key is immutable; add a new publisher pin'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_community_pack_publisher_no_delete
    BEFORE DELETE ON community_pack_publishers
    BEGIN SELECT RAISE(ABORT,'Pinned community publisher keys are retained as audit history'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_calculation_complete_insert
    BEFORE INSERT ON calculation_runs
    WHEN NEW.status='completed' AND
      (COALESCE(NEW.output_json,NEW.result_json) IS NULL OR
       NEW.trace_json IS NULL OR NEW.trace_sha256 IS NULL)
    BEGIN SELECT RAISE(ABORT,'completed CalculationRun requires output and trace'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_calculation_complete_update
    BEFORE UPDATE ON calculation_runs
    WHEN OLD.status IN('completed','failed','cancelled','interrupted')
      OR (NEW.status='completed' AND
        (COALESCE(NEW.output_json,NEW.result_json) IS NULL OR
         NEW.trace_json IS NULL OR NEW.trace_sha256 IS NULL))
    BEGIN SELECT RAISE(ABORT,'terminal CalculationRun is immutable or incomplete'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_calculation_terminal_no_delete
    BEFORE DELETE ON calculation_runs
    WHEN OLD.status IN('completed','failed','cancelled','interrupted')
    BEGIN SELECT RAISE(ABORT,'terminal CalculationRun is immutable'); END''',
];

/// Installation authority and restore isolation. This migration is additive:
/// prior event, approval, and remote epoch records remain available for audit.
const List<String> schemaV3Statements = [
  '''CREATE TABLE IF NOT EXISTS local_installation_identity (
    singleton_id INTEGER PRIMARY KEY CHECK(singleton_id=1),
    active_device_id TEXT NOT NULL REFERENCES devices(device_id),
    authority_generation INTEGER NOT NULL CHECK(authority_generation > 0),
    initialized_at_utc TEXT NOT NULL,
    restored_from_backup_id TEXT
  )''',
  '''ALTER TABLE approval_receipts ADD COLUMN issuer_device_id TEXT REFERENCES devices(device_id)''',
  '''ALTER TABLE approval_receipts ADD COLUMN authority_generation INTEGER''',
  '''ALTER TABLE ai_provider_profiles ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE ai_consent_receipts ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE todo_integration_state ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE todo_integration_state ADD COLUMN needs_reauthorization INTEGER NOT NULL DEFAULT 0
    CHECK(needs_reauthorization IN(0,1))''',
  '''ALTER TABLE remote_targets ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1''',
  '''ALTER TABLE remote_target_epochs ADD COLUMN authority_generation INTEGER NOT NULL DEFAULT 1''',
  '''CREATE TABLE IF NOT EXISTS remote_target_epoch_authorizations (
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
  )''',
  '''CREATE INDEX IF NOT EXISTS idx_remote_epoch_authorizations_generation
    ON remote_target_epoch_authorizations(authority_generation,target_id,epoch)''',
  '''CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_local_authority
    BEFORE INSERT ON approval_receipts
    WHEN NEW.issuer_device_id IS NOT
         (SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1) OR
         NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt must be issued by the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_ai_profile_local_authority_insert
    BEFORE INSERT ON ai_provider_profiles
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'AI provider profile must belong to the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_ai_consent_local_authority_insert
    BEFORE INSERT ON ai_consent_receipts
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'AI consent must belong to the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_todo_state_local_authority_insert
    BEFORE INSERT ON todo_integration_state
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1) OR
         NEW.primary_device_id IS NOT
         (SELECT active_device_id FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'To Do profile must belong to the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_target_local_authority_insert
    BEFORE INSERT ON remote_targets
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'Remote target must belong to the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_local_authority_insert
    BEFORE INSERT ON remote_target_epochs
    WHEN NEW.authority_generation IS NOT
         (SELECT authority_generation FROM local_installation_identity WHERE singleton_id=1)
    BEGIN SELECT RAISE(ABORT,'Remote target epoch must belong to the active local authority'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_local_approval
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
             AND json_extract(a.scope_json,'\$.target_id')=NEW.target_id
             AND json_type(a.scope_json,'\$.epoch')='integer'
             AND json_extract(a.scope_json,'\$.epoch')=NEW.epoch
             AND json_type(a.scope_json,'\$.provider')='text'
             AND json_extract(a.scope_json,'\$.provider')=NEW.provider
             AND json_type(a.scope_json,'\$.endpoint_fingerprint')='text'
             AND json_extract(a.scope_json,'\$.endpoint_fingerprint')=NEW.endpoint_fingerprint
             AND ((NEW.key_id IS NULL AND json_type(a.scope_json,'\$.key_id')='null') OR
                  (NEW.key_id IS NOT NULL AND json_type(a.scope_json,'\$.key_id')='text' AND
                   json_extract(a.scope_json,'\$.key_id')=NEW.key_id))
             AND ((NEW.key_fingerprint IS NULL AND json_type(a.scope_json,'\$.key_fingerprint')='null') OR
                  (NEW.key_fingerprint IS NOT NULL AND json_type(a.scope_json,'\$.key_fingerprint')='text' AND
                   json_extract(a.scope_json,'\$.key_fingerprint')=NEW.key_fingerprint))
             AND (SELECT count(*) FROM json_each(a.scope_json))=6
         )
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization requires an exact active local approval'); END''',
  '''UPDATE ai_consent_receipts SET revoked_at_utc=COALESCE(revoked_at_utc,approved_at_utc)''',
  '''CREATE TABLE IF NOT EXISTS remote_asset_deletion_reviews (
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
  )''',
  '''CREATE INDEX IF NOT EXISTS idx_remote_asset_deletion_review_state
    ON remote_asset_deletion_reviews(status,requested_at_utc)''',
  '''CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_scope_immutable
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
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt authority and scope are immutable'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_approval_receipt_no_delete
    BEFORE DELETE ON approval_receipts
    BEGIN SELECT RAISE(ABORT,'ApprovalReceipt history is retained for audit'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization is immutable; append a new generation'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_epoch_authorization_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorizations are retained for audit'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_asset_deletion_review_transition
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
    BEGIN SELECT RAISE(ABORT,'Remote deletion review has an invalid state transition'); END''',
  '''CREATE TRIGGER IF NOT EXISTS trig_remote_asset_deletion_review_no_delete
    BEFORE DELETE ON remote_asset_deletion_reviews
    BEGIN SELECT RAISE(ABORT,'Remote deletion review history is retained'); END''',
];

/// Allows a user to renew a local historical-target authorization after a
/// previous approval expires or is revoked, while retaining each grant.
const List<String> schemaV4Statements = [
  '''DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_local_approval''',
  '''DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_no_update''',
  '''DROP TRIGGER IF EXISTS trig_remote_epoch_authorization_no_delete''',
  '''DROP INDEX IF EXISTS idx_remote_epoch_authorizations_generation''',
  '''ALTER TABLE remote_target_epoch_authorizations RENAME TO remote_target_epoch_authorizations_v3''',
  '''CREATE TABLE remote_target_epoch_authorizations (
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
  )''',
  '''INSERT INTO remote_target_epoch_authorizations
    (authorization_id,authorization_revision,target_id,epoch,authority_generation,provider,
     endpoint_fingerprint,key_id,key_fingerprint,credential_secret_ref,encryption_secret_ref,
     approval_ref,authorized_at_utc,command_id)
    SELECT 'legacy:' || target_id || ':' || epoch || ':' || authority_generation,1,target_id,epoch,
     authority_generation,provider,endpoint_fingerprint,key_id,key_fingerprint,credential_secret_ref,
     encryption_secret_ref,approval_ref,authorized_at_utc,command_id
    FROM remote_target_epoch_authorizations_v3''',
  '''CREATE INDEX idx_remote_epoch_authorizations_generation
    ON remote_target_epoch_authorizations(target_id,epoch,authority_generation,authorization_revision DESC)''',
  '''CREATE TRIGGER trig_remote_epoch_authorization_local_approval
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
             AND json_extract(a.scope_json,'\$.target_id')=NEW.target_id
             AND json_type(a.scope_json,'\$.epoch')='integer'
             AND json_extract(a.scope_json,'\$.epoch')=NEW.epoch
             AND json_type(a.scope_json,'\$.provider')='text'
             AND json_extract(a.scope_json,'\$.provider')=NEW.provider
             AND json_extract(e.policy_json,'\$.provider')=NEW.provider
             AND json_type(a.scope_json,'\$.endpoint_fingerprint')='text'
             AND json_extract(a.scope_json,'\$.endpoint_fingerprint')=NEW.endpoint_fingerprint
             AND ((NEW.key_id IS NULL AND json_type(a.scope_json,'\$.key_id')='null') OR
                  (NEW.key_id IS NOT NULL AND json_type(a.scope_json,'\$.key_id')='text' AND
                   json_extract(a.scope_json,'\$.key_id')=NEW.key_id))
             AND ((NEW.key_fingerprint IS NULL AND json_type(a.scope_json,'\$.key_fingerprint')='null') OR
                  (NEW.key_fingerprint IS NOT NULL AND json_type(a.scope_json,'\$.key_fingerprint')='text' AND
                   json_extract(a.scope_json,'\$.key_fingerprint')=NEW.key_fingerprint))
             AND (SELECT count(*) FROM json_each(a.scope_json))=6
             AND NEW.key_id IS json_extract(e.policy_json,'\$.key_id')
             AND NEW.credential_secret_ref IS NOT NULL
             AND NEW.credential_secret_ref IS NOT e.secret_ref
             AND (NEW.key_id IS NULL OR NEW.encryption_secret_ref IS NOT json_extract(e.policy_json,'\$.key_id'))
         )
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization requires fresh references and exact active local approval'); END''',
  '''CREATE TRIGGER trig_remote_epoch_authorization_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization is immutable; append a new revision'); END''',
  '''CREATE TRIGGER trig_remote_epoch_authorization_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorizations are retained for audit'); END''',
  '''CREATE TRIGGER trig_remote_epoch_authorization_v3_no_update
    BEFORE UPDATE ON remote_target_epoch_authorizations_v3
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization audit is immutable'); END''',
  '''CREATE TRIGGER trig_remote_epoch_authorization_v3_no_delete
    BEFORE DELETE ON remote_target_epoch_authorizations_v3
    BEGIN SELECT RAISE(ABORT,'Historical epoch authorization audit is retained'); END''',
];
