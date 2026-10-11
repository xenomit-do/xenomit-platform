-- docs/12 §12.1 + docs/08 §8.3a: single-use invite codes. Only the sha256
-- of the code is stored; the code itself is shown once at creation.
CREATE TABLE IF NOT EXISTS invites (
    code_hash           TEXT PRIMARY KEY,
    created_by          TEXT NOT NULL,
    plan_id             TEXT NOT NULL REFERENCES plans(id),
    used_by             TEXT,
    expires_at_unix_ms  BIGINT,
    created_at_unix_ms  BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS invites_open
    ON invites (expires_at_unix_ms)
    WHERE used_by IS NULL;
