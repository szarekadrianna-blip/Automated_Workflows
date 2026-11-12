-- Write your own diagnostic SQL for the five new tables.
-- One worked example follows. Add your case queries below it.
SELECT r.run_id,r.command,a.item_id,a.asset_key,s.aoi_key,d.status,d.stage,
       d.network_bytes,d.http_status,d.error_code,d.error_message
FROM download_attempts d JOIN runs r ON r.run_id=d.run_id
JOIN subset_requests s ON s.subset_id=d.subset_id
JOIN assets a ON a.asset_id=s.asset_id
ORDER BY d.started_at,d.attempt_id;

PRAGMA foreign_keys = ON;

-- Case A (network case): failed band, partial success, and the later recovery.
-- Use cases/network/state/catalogue.sqlite.

-- A1. Attempt history per band: each attempt, its run (and the run's outcome), the
--     attempt number within that band's request, and the artifact it ended with.
--     Expected: red succeeded then reused; nir failed (no artifact) then succeeded.
SELECT a.asset_key,
       ROW_NUMBER() OVER (PARTITION BY d.subset_id ORDER BY d.started_at, d.attempt_id) AS attempt_no,
       r.run_id, r.command, r.status AS run_status,
       d.status AS attempt_status, d.stage, d.error_code, d.network_bytes,
       substr(d.artifact_id, 1, 12) AS artifact, d.started_at, d.finished_at
FROM download_attempts d
JOIN runs r            ON r.run_id    = d.run_id
JOIN subset_requests s ON s.subset_id = d.subset_id
JOIN assets a          ON a.asset_id  = s.asset_id
ORDER BY a.asset_key, d.started_at, d.attempt_id;

-- A2. Current state of each band against its history: the failed row is preserved even
--     though the request is now ready with an available file.
SELECT a.asset_key, s.status AS request_status,
       SUM(d.status = 'failed')    AS failed_attempts,
       SUM(d.status = 'succeeded') AS succeeded_attempts,
       SUM(d.status = 'reused')    AS reused_attempts,
       GROUP_CONCAT(DISTINCT d.error_code) AS error_codes,
       substr(s.latest_artifact_id, 1, 12) AS latest_artifact,
       (SELECT l.status FROM artifact_locations l WHERE l.artifact_id = s.latest_artifact_id) AS location_status
FROM subset_requests s
JOIN assets a ON a.asset_id = s.asset_id
LEFT JOIN download_attempts d ON d.subset_id = s.subset_id
GROUP BY s.subset_id
ORDER BY a.asset_key;

-- Case B (missing case): successful historical acquisition, but the file is gone now.
-- Use cases/missing/state/catalogue.sqlite.

-- B1. Artifacts whose creating attempt succeeded but whose location is currently missing
--     or corrupt. Returns rows after the verify run and before recovery; after recovery
--     the location is 'available' again, so use B2 for the history.
SELECT a.asset_key, substr(ar.artifact_id, 1, 12) AS artifact,
       cr.status AS creating_attempt_status, cr.finished_at AS stored_at,
       l.status AS location_status, l.checked_at, l.local_path
FROM artifact_locations l
JOIN artifacts ar          ON ar.artifact_id = l.artifact_id
JOIN download_attempts cr  ON cr.attempt_id  = ar.created_by_attempt_id
JOIN subset_requests s     ON s.subset_id    = ar.subset_id
JOIN assets a              ON a.asset_id     = s.asset_id
WHERE l.status IN ('missing', 'corrupt')
ORDER BY a.asset_key;

-- B2. The same story as history, valid before and after recovery: the original success,
--     the failed verification (FILE_MISSING etc.) and what happened afterwards.
SELECT a.asset_key, d.started_at, r.command, d.status, d.stage, d.error_code,
       d.error_message, d.network_bytes, substr(d.artifact_id, 1, 12) AS artifact
FROM download_attempts d
JOIN runs r            ON r.run_id    = d.run_id
JOIN subset_requests s ON s.subset_id = d.subset_id
JOIN assets a          ON a.asset_id  = s.asset_id
WHERE d.subset_id IN (SELECT subset_id FROM download_attempts
                       WHERE error_code IN ('FILE_MISSING', 'FILE_CORRUPT')
                          OR stage = 'cache_verify' AND status = 'failed')
ORDER BY a.asset_key, d.started_at, d.attempt_id;

-- B3. Requests that claim ready but have no available file. Empty when archive and disk
--     agree; use before recovery in the missing case.
SELECT a.asset_key, s.status AS request_status, substr(s.latest_artifact_id, 1, 12) AS artifact,
       (SELECT GROUP_CONCAT(l.status) FROM artifact_locations l
         WHERE l.artifact_id = s.latest_artifact_id) AS location_statuses
FROM subset_requests s
JOIN assets a ON a.asset_id = s.asset_id
WHERE s.status = 'ready'
  AND NOT EXISTS (SELECT 1 FROM artifact_locations l
                   WHERE l.artifact_id = s.latest_artifact_id AND l.status = 'available');

-- AOI identity: one source band, separate requests for different AOIs.

-- C1. Source assets that have more than one request, with each AOI's own key, box,
--     recipe, state and artifact. Empty until a second AOI has been acquired.
SELECT a.asset_key, a.item_id, substr(a.asset_id, 1, 12) AS asset,
       substr(s.aoi_key, 1, 12) AS aoi, s.aoi_json, s.recipe_version, s.status,
       substr(s.latest_artifact_id, 1, 12) AS artifact
FROM subset_requests s
JOIN assets a ON a.asset_id = s.asset_id
WHERE s.asset_id IN (SELECT asset_id FROM subset_requests
                      GROUP BY asset_id HAVING COUNT(DISTINCT aoi_key) > 1)
ORDER BY a.asset_key, s.aoi_key;

-- C2. Same check as a count per source band, plus how many distinct artifacts it has.
SELECT a.asset_key, COUNT(DISTINCT s.aoi_key) AS aois, COUNT(*) AS requests,
       COUNT(DISTINCT s.latest_artifact_id) AS artifacts
FROM subset_requests s JOIN assets a ON a.asset_id = s.asset_id
GROUP BY s.asset_id;