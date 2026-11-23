-- Lab 04: write all six new CREATE TABLE statements here.
-- Use SCHEMA_CONTRACT.md. Keep the existing Lab 3 tables.
-- IDs and checksums are supplied by Python. Do not DROP existing tables.

CREATE TABLE processing_artifacts (
    artifact_id        TEXT NOT NULL PRIMARY KEY CHECK (length(artifact_id) > 0),
    source_artifact_id TEXT UNIQUE
        CHECK (source_artifact_id IS NULL OR length(source_artifact_id) > 0),
    sha256             TEXT NOT NULL
        CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes         INTEGER NOT NULL CHECK (size_bytes > 0),
    raster_json        TEXT NOT NULL CHECK (json_valid(raster_json)),
    lineage_json       TEXT NOT NULL CHECK (json_valid(lineage_json)),
    created_at         TEXT NOT NULL CHECK (length(created_at) > 0),
    FOREIGN KEY (source_artifact_id) REFERENCES artifacts (artifact_id)
);
-- sha256 is deliberately NOT unique: interpretation and lineage also matter.
CREATE INDEX idx_processing_artifacts_sha256 ON processing_artifacts (sha256);

-- Current known paths for an artifact. A path is not proof of availability.
CREATE TABLE processing_artifact_locations (
    location_id TEXT NOT NULL PRIMARY KEY CHECK (length(location_id) > 0),
    artifact_id TEXT NOT NULL,
    local_path  TEXT NOT NULL UNIQUE CHECK (length(local_path) > 0),
    status      TEXT NOT NULL CHECK (status IN ('available', 'missing', 'corrupt')),
    checked_at  TEXT NOT NULL CHECK (length(checked_at) > 0),
    FOREIGN KEY (artifact_id) REFERENCES processing_artifacts (artifact_id)
);
CREATE INDEX idx_processing_locations_artifact
    ON processing_artifact_locations (artifact_id);

-- One specified calculation under the declared (strict) equivalence policy.
CREATE TABLE processing_requests (
    request_id      TEXT NOT NULL PRIMARY KEY CHECK (length(request_id) > 0),
    fingerprint     TEXT NOT NULL UNIQUE
        CHECK (length(fingerprint) = 64 AND fingerprint NOT GLOB '*[^0-9a-f]*'),
    stage           TEXT NOT NULL CHECK (length(stage) > 0),
    normalized_json TEXT NOT NULL CHECK (json_valid(normalized_json)),
    created_at      TEXT NOT NULL CHECK (length(created_at) > 0)
);

-- An artifact filling one named role in a request. Roles are names, not positions.
CREATE TABLE processing_inputs (
    request_id  TEXT NOT NULL,
    role        TEXT NOT NULL CHECK (length(role) > 0),
    artifact_id TEXT NOT NULL,
    PRIMARY KEY (request_id, role),
    FOREIGN KEY (request_id)  REFERENCES processing_requests (request_id),
    FOREIGN KEY (artifact_id) REFERENCES processing_artifacts (artifact_id)
);
CREATE INDEX idx_processing_inputs_artifact ON processing_inputs (artifact_id);

-- One invocation trying to satisfy a request. Rows are kept forever.
CREATE TABLE processing_attempts (
    attempt_id             TEXT NOT NULL PRIMARY KEY CHECK (length(attempt_id) > 0),
    request_id             TEXT NOT NULL,
    status                 TEXT NOT NULL
        CHECK (status IN ('running', 'succeeded', 'failed', 'interrupted', 'reused')),
    -- Free-text stage (validate_inputs, calculate, write_temporary, validate_temporary,
    -- before_rename, register_output, complete); validated by Python, not a CHECK.
    stage                  TEXT NOT NULL CHECK (length(stage) > 0),
    started_at             TEXT NOT NULL CHECK (length(started_at) > 0),
    finished_at            TEXT CHECK (finished_at IS NULL OR length(finished_at) > 0),
    environment_json       TEXT NOT NULL CHECK (json_valid(environment_json)),
    original_config        TEXT NOT NULL,
    resolved_config_json   TEXT NOT NULL CHECK (json_valid(resolved_config_json)),
    temp_path              TEXT NOT NULL UNIQUE CHECK (length(temp_path) > 0),
    final_path             TEXT NOT NULL UNIQUE CHECK (length(final_path) > 0),
    log_path               TEXT NOT NULL UNIQUE CHECK (length(log_path) > 0),
    receipt_json           TEXT CHECK (receipt_json IS NULL OR json_valid(receipt_json)),
    error_code             TEXT,
    error_message          TEXT,
    reused_from_attempt_id TEXT,
    FOREIGN KEY (request_id) REFERENCES processing_requests (request_id),
    -- Reused attempt and its producer must belong to the same request.
    -- MATCH SIMPLE: not checked while reused_from_attempt_id is NULL.
    FOREIGN KEY (reused_from_attempt_id, request_id)
        REFERENCES processing_attempts (attempt_id, request_id),
    -- Parent key for the composite self-reference above.
    UNIQUE (attempt_id, request_id),
    CHECK (temp_path <> final_path),
    -- running <=> no finish time.
    CHECK ((status = 'running' AND finished_at IS NULL)
        OR (status <> 'running' AND finished_at IS NOT NULL)),
    CHECK (status <> 'succeeded' OR receipt_json IS NOT NULL),
    CHECK (status NOT IN ('failed', 'interrupted')
        OR (error_code IS NOT NULL AND length(error_code) > 0)),
    -- reused_from required only for reused; NULL for every other status.
    CHECK ((status = 'reused' AND reused_from_attempt_id IS NOT NULL
            AND reused_from_attempt_id <> attempt_id)
        OR (status <> 'reused' AND reused_from_attempt_id IS NULL))
);
CREATE INDEX idx_processing_attempts_request ON processing_attempts (request_id);
CREATE INDEX idx_processing_attempts_reused
    ON processing_attempts (reused_from_attempt_id, request_id);

-- An artifact returned by one attempt under one output role. A reused attempt links
-- the existing artifact; follow it to a 'succeeded' attempt to find true production.
CREATE TABLE processing_outputs (
    attempt_id  TEXT NOT NULL,
    role        TEXT NOT NULL CHECK (length(role) > 0),
    artifact_id TEXT NOT NULL,
    PRIMARY KEY (attempt_id, role),
    FOREIGN KEY (attempt_id)  REFERENCES processing_attempts (attempt_id),
    FOREIGN KEY (artifact_id) REFERENCES processing_artifacts (artifact_id)
);
CREATE INDEX idx_processing_outputs_artifact ON processing_outputs (artifact_id);