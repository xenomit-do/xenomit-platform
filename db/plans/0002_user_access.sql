-- docs/12 §12.1–2: the orchestrator's read-only copy of the panel `User`
-- columns it enforces (planId, status). The panel owns the real table;
-- this copy is refreshed by the deploy that syncs the directory.
CREATE TABLE IF NOT EXISTS user_access (
    user_id     TEXT PRIMARY KEY,
    plan_id     TEXT REFERENCES plans(id),
    -- invited | active | suspended (docs/12 §12.1)
    status      TEXT NOT NULL DEFAULT 'invited'
                CHECK (status IN ('invited','active','suspended')),
    synced_at_unix_ms BIGINT NOT NULL
);
