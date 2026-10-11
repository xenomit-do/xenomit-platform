-- docs/12 §12.2 seed plans (placeholders to tune): `owner` unlimited,
-- `friends` 5 bots + pool & fixed + all channels. `standard`/`pro` arrive
-- with customers.
INSERT INTO plans (id, name, active, max_bots, max_running_bots,
                   proxy_modes, pool_access, channels,
                   rollout_priority, handoff_priority,
                   retention_days_after_delete)
VALUES
    ('owner',   'Owner',   TRUE, NULL, NULL,
     '["pool","fixed"]', TRUE, '["stable","canary","pinned"]', 100, 100, 30),
    ('friends', 'Friends', TRUE, 5, 5,
     '["pool","fixed"]', TRUE, '["stable","canary","pinned"]', 0, 0, 30)
ON CONFLICT (id) DO NOTHING;
