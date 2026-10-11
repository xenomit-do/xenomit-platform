-- docs/12 §12.2: UsageRecord — append-only, written by the orchestrator's
-- hourly meter (plans::metering). PK (bot_id, hour) makes the hourly
-- recompute of the cursor hour idempotent (INSERT .. ON CONFLICT).
-- Retention: 13 months (docs/12 §12.4); the purge job deletes by `hour`.
CREATE TABLE IF NOT EXISTS usage_records (
    bot_id         TEXT NOT NULL,
    tenant         TEXT NOT NULL,
    hour_unix_ms   BIGINT NOT NULL,
    running_s      BIGINT NOT NULL DEFAULT 0,
    offline_s      BIGINT NOT NULL DEFAULT 0,
    needs_human_s  BIGINT NOT NULL DEFAULT 0,
    -- User-caused pause/stop seconds: the SLO carve-out of §12.5.4.
    user_paused_s  BIGINT NOT NULL DEFAULT 0,
    version        TEXT NOT NULL DEFAULT '',
    plan_id        TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (bot_id, hour_unix_ms)
);

CREATE INDEX IF NOT EXISTS usage_records_tenant
    ON usage_records (tenant, hour_unix_ms);
