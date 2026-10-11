-- docs/12 §12.2: Plan — authored in the panel DB, enforced read-only here.
-- JSONB for the array columns keeps the table JSON-shaped like the rest of
-- the panel schema (docs/08 §8.2) and maps straight onto the serde types.
CREATE TABLE IF NOT EXISTS plans (
    id                          TEXT PRIMARY KEY,
    name                        TEXT NOT NULL,
    active                      BOOLEAN NOT NULL DEFAULT TRUE,
    -- NULL = unlimited (the `owner` plan).
    max_bots                    INTEGER,
    max_running_bots            INTEGER,
    proxy_modes                 JSONB NOT NULL DEFAULT '["pool","fixed"]',
    pool_access                 BOOLEAN NOT NULL DEFAULT FALSE,
    channels                    JSONB NOT NULL DEFAULT '["stable"]',
    rollout_priority            INTEGER NOT NULL DEFAULT 0,
    handoff_priority            INTEGER NOT NULL DEFAULT 0,
    retention_days_after_delete INTEGER NOT NULL DEFAULT 30,
    -- Nullable until billing exists (docs/12 §12.5, ADR-24).
    price_cents                 INTEGER,
    interval                    TEXT CHECK (interval IN ('month','year'))
);
