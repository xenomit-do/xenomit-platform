-- docs/12 §12.2: Subscription — one row per user. All provider fields are
-- nullable while billing is off; the BillingProvider webhook flow of
-- §12.5.2 fills them and flips `status`.
CREATE TABLE IF NOT EXISTS subscriptions (
    user_id                    TEXT PRIMARY KEY,
    plan_id                    TEXT NOT NULL REFERENCES plans(id),
    status                     TEXT NOT NULL DEFAULT 'active'
                               CHECK (status IN ('trialing','active','past_due','canceled')),
    provider                   TEXT,
    provider_customer_id       TEXT,
    provider_subscription_id   TEXT,
    current_period_end_unix_ms BIGINT,
    updated_at_unix_ms         BIGINT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_provider_sub
    ON subscriptions (provider, provider_subscription_id)
    WHERE provider_subscription_id IS NOT NULL;
