-- Lab Workspace additive schema migration v5.
-- Project browse-copy roots are device-local; the immutable CAS remains authoritative.

PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

CREATE TABLE project_storage_locations (
    project_id TEXT NOT NULL REFERENCES projects(project_id),
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    root_directory TEXT NOT NULL CHECK(length(trim(root_directory))>0),
    is_active INTEGER NOT NULL CHECK(is_active IN(0,1)),
    is_default INTEGER NOT NULL CHECK(is_default IN(0,1)),
    manifest_sha256 TEXT CHECK(manifest_sha256 IS NULL OR length(manifest_sha256)=64),
    pending_manifest_sha256 TEXT CHECK(pending_manifest_sha256 IS NULL OR length(pending_manifest_sha256)=64),
    manifest_status TEXT NOT NULL DEFAULT 'not_generated'
      CHECK(manifest_status IN('not_generated','ready','missing','externally_changed','blocked')),
    last_generated_at_utc TEXT,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY(project_id,device_id,root_directory)
);

CREATE UNIQUE INDEX idx_project_storage_one_active_per_project
    ON project_storage_locations(project_id) WHERE is_active=1;

CREATE UNIQUE INDEX idx_project_storage_active_root
    ON project_storage_locations(root_directory COLLATE NOCASE) WHERE is_active=1;

CREATE TABLE project_storage_files (
    project_id TEXT NOT NULL,
    device_id TEXT NOT NULL REFERENCES devices(device_id),
    root_directory TEXT NOT NULL,
    asset_id TEXT NOT NULL REFERENCES assets(asset_id),
    relative_path TEXT NOT NULL CHECK(length(trim(relative_path))>0),
    display_name TEXT NOT NULL,
    expected_sha256 TEXT NOT NULL CHECK(length(expected_sha256)=64),
    observed_sha256 TEXT CHECK(observed_sha256 IS NULL OR length(observed_sha256)=64),
    state TEXT NOT NULL CHECK(state IN('pending','copied','externally_changed','missing',
      'source_missing','failed','conflict','soft_deleted','unlinked_retained')),
    copied_at_utc TEXT,
    checked_at_utc TEXT,
    error_message TEXT,
    PRIMARY KEY(project_id,device_id,root_directory,asset_id),
    UNIQUE(project_id,device_id,root_directory,relative_path),
    FOREIGN KEY(project_id,device_id,root_directory)
      REFERENCES project_storage_locations(project_id,device_id,root_directory)
);

CREATE INDEX idx_project_storage_files_state
    ON project_storage_files(project_id,device_id,root_directory,state);

PRAGMA user_version = 5;

COMMIT;
