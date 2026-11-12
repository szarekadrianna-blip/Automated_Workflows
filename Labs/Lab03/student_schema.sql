-- Lab 03: write ALL FIVE complete CREATE TABLE statements here.
-- Read SCHEMA_CONTRACT.md for column names, types and integrity requirements.
-- Supply assets, subset_requests, download_attempts, artifacts, artifact_locations.
-- Include your chosen primary/foreign keys, uniqueness rules and CHECK constraints.
-- Do not change or recreate the existing five Lab 02 tables.
-- Run python check_lab03.py, then init your archive after checks pass.

-- Lab 03: five new tables. The Lab 02 tables (scenes, runs, ...) are NOT touched here.

-- One observed metadata revision of a scene's red or nir asset.
CREATE TABLE assets (
    asset_id        TEXT NOT NULL PRIMARY KEY CHECK (length(asset_id) > 0),
    collection      TEXT NOT NULL CHECK (length(collection) > 0),
    item_id         TEXT NOT NULL CHECK (length(item_id) > 0),
    asset_key       TEXT NOT NULL CHECK (asset_key IN ('red', 'nir')),
    source_url      TEXT NOT NULL CHECK (length(source_url) > 0),
    metadata_json   TEXT NOT NULL CHECK (json_valid(metadata_json)),
    metadata_sha256 TEXT NOT NULL
        CHECK (length(metadata_sha256) = 64 AND metadata_sha256 NOT GLOB '*[^0-9a-f]*'),
    created_at      TEXT NOT NULL CHECK (length(created_at) > 0),
    FOREIGN KEY (collection, item_id) REFERENCES scenes (collection, item_id),
    UNIQUE (collection, item_id, asset_key, metadata_sha256)
);

CREATE INDEX idx_assets_scene ON assets (collection, item_id);

-- One asset + AOI + recipe combination.
CREATE TABLE subset_requests (
    subset_id          TEXT NOT NULL PRIMARY KEY CHECK (length(subset_id) > 0),
    asset_id           TEXT NOT NULL,
    aoi_key            TEXT NOT NULL CHECK (length(aoi_key) > 0),
    aoi_json           TEXT NOT NULL CHECK (json_valid(aoi_json)),
    recipe_version     TEXT NOT NULL CHECK (length(recipe_version) > 0),
    status             TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
    latest_artifact_id TEXT,
    updated_at         TEXT NOT NULL CHECK (length(updated_at) > 0),
    FOREIGN KEY (asset_id) REFERENCES assets (asset_id),
    -- Latest artifact must belong to THIS request (NULL = not enforced, MATCH SIMPLE).
    FOREIGN KEY (latest_artifact_id, subset_id)
        REFERENCES artifacts (artifact_id, subset_id),
    UNIQUE (asset_id, aoi_key, recipe_version),
    CHECK (status <> 'ready' OR latest_artifact_id IS NOT NULL)
);

CREATE INDEX idx_subset_requests_asset ON subset_requests (asset_id);
CREATE INDEX idx_subset_requests_latest ON subset_requests (latest_artifact_id, subset_id);

-- One attempt to acquire or verify a subset. Failed rows are kept forever.
CREATE TABLE download_attempts (
    attempt_id     TEXT NOT NULL PRIMARY KEY CHECK (length(attempt_id) > 0),
    subset_id      TEXT NOT NULL,
    run_id         TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'reused', 'failed')),
    -- Free-text pipeline stage (cache_verify, read_window, write_subset, validate_subset,
    -- before_finalize, finalize, register, complete); validated by Python, not by a CHECK.
    stage          TEXT NOT NULL CHECK (length(stage) > 0),
    started_at     TEXT NOT NULL CHECK (length(started_at) > 0),
    finished_at    TEXT,
    network_bytes  INTEGER NOT NULL DEFAULT 0 CHECK (network_bytes >= 0),
    http_status    INTEGER,
    artifact_id    TEXT,
    error_code     TEXT,
    error_message  TEXT,
    FOREIGN KEY (subset_id) REFERENCES subset_requests (subset_id),
    FOREIGN KEY (run_id) REFERENCES runs (run_id),
    -- Referenced artifact must belong to the same request.
    FOREIGN KEY (artifact_id, subset_id)
        REFERENCES artifacts (artifact_id, subset_id),
    -- Target of artifacts' composite FK.
    UNIQUE (attempt_id, subset_id),
    -- running <=> no finish time.
    CHECK ((status = 'running' AND finished_at IS NULL)
        OR (status <> 'running' AND finished_at IS NOT NULL)),
    CHECK (status NOT IN ('succeeded', 'reused') OR artifact_id IS NOT NULL)
);

CREATE INDEX idx_attempts_run ON download_attempts (run_id);
CREATE INDEX idx_attempts_subset ON download_attempts (subset_id);
CREATE INDEX idx_attempts_artifact ON download_attempts (artifact_id, subset_id);

-- One distinct, successfully stored subset byte sequence.
CREATE TABLE artifacts (
    artifact_id           TEXT NOT NULL PRIMARY KEY CHECK (length(artifact_id) > 0),
    subset_id             TEXT NOT NULL,
    created_by_attempt_id TEXT NOT NULL,
    sha256                TEXT NOT NULL
        CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
    size_bytes            INTEGER NOT NULL CHECK (size_bytes > 0),
    raster_json           TEXT NOT NULL CHECK (json_valid(raster_json)),
    created_at            TEXT NOT NULL CHECK (length(created_at) > 0),
    FOREIGN KEY (subset_id) REFERENCES subset_requests (subset_id),
    -- Creating attempt must belong to the same request.
    FOREIGN KEY (created_by_attempt_id, subset_id)
        REFERENCES download_attempts (attempt_id, subset_id),
    -- Target of the composite FKs from subset_requests and download_attempts.
    UNIQUE (artifact_id, subset_id),
    -- Identical bytes for a request reuse one artifact.
    UNIQUE (subset_id, sha256)
);

CREATE INDEX idx_artifacts_creator ON artifacts (created_by_attempt_id, subset_id);

-- Known local paths for an artifact; status is refreshed by filesystem checks.
CREATE TABLE artifact_locations (
    location_id TEXT NOT NULL PRIMARY KEY CHECK (length(location_id) > 0),
    artifact_id TEXT NOT NULL,
    local_path  TEXT NOT NULL UNIQUE CHECK (length(local_path) > 0),
    status      TEXT NOT NULL CHECK (status IN ('available', 'missing', 'corrupt')),
    checked_at  TEXT NOT NULL CHECK (length(checked_at) > 0),
    FOREIGN KEY (artifact_id) REFERENCES artifacts (artifact_id)
);

CREATE INDEX idx_locations_artifact ON artifact_locations (artifact_id);