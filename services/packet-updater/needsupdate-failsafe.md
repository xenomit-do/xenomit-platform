# `NeedsUpdate` fail-safe contract

When Bigpoint ships a client before our rollout lands, bots start hitting a
`VersionCommand` mismatch on the game socket. Continuing to hammer the login
server with a stale client is both useless and a ban signal — so the bot
**fails safe, not loud** (docs/07 §7.1 "Fail-safe when the game moves first").

This is the contract every side must honor; the code that implements it
lives in `xenomit-botd`, `fleet-types` and the operator, but the *rules* are
stable enough to pin down here.

## The chain

```
bot sees version mismatch on the wire
  → self-drain: find safe point → snapshot → outbox flush → logout
  → process exits 68 (VersionMismatch)          [restartPolicy: Never]
  → operator classifies exit 68 → phase NeedsUpdate, NO retry, no successor
  → xenomit.bot.phase{phase="needs_update"} gauge rises
  → high-urgency alert fires (observability/alerts)
  → packet-updater flow delivers a new botd digest
  → BotRollout fast lane resumes the bot via the normal handoff:
    arm → activate → restore(snapshot taken on the way out)
```

## Rules per side

| Side | Contract |
|---|---|
| `botd` | On `VersionCommand` mismatch: drain to a safe point, commit the snapshot, flush the outbox, log out, exit **68**. Never blind-retry login. The snapshot preserves state across the outage window. |
| Pod | `restartPolicy: Never` — kubelet must not restart it (docs/04 §4.2). |
| Operator | `classify(68) → version_mismatch → MarkNeedsUpdate`: set `status.phase=NeedsUpdate`, create no successor, run no retry loop. The bot sits parked until a rollout reaches it (fleet-types `exit_code.rs`, `phase.rs`). |
| RolloutController | A `NeedsUpdate` bot resumes only via a rollout **release** to the new digest: a fresh successor is armed on the target image and activated — there is no live predecessor session, so nothing is drained. It is already down, so `maxOffline` doesn't gate it — that's what makes the fast lane fast (docs/07 §7.3). |
| Telemetry | The fleet gauge `xenomit.bot.phase{phase="needs_update"}` counts parked bots. `> 0` sustained means "the game changed" → high-urgency alert, never auto-rollback (there is nothing to roll back *to* — the old client is obsolete). |
| Alerting | `NeedsUpdate > 0` pages (it's a fleet outage, not a bot fault). Routed with the game-update alert that carries `upgrade.json` `shape_changes`. |
| Human | `exit_class=review` (exit 30) never auto-rolls: a human checks the bound builders/handlers first. Bots stay parked until then — that's the design, not a stuck state. |

## What it is NOT

* **Not a crash.** No backoff, no quarantine, no crash-budget spend.
  `is_settled()` treats it like `Paused`/`NeedsHuman` — reconcile is idle
  until spec or external change.
* **Not `Failed` / not `InvalidConfig`.** The bot is healthy; the world
  moved. Exit 70 (strict-restore) and 64 (config) have their own actions.
* **Not forever.** The park survives restarts of the operator itself —
  phase lives on the CR status, so a controller restart re-reads it.

## SLO framing

Parked-in-`NeedsUpdate` time is *planned* unavailability: it counts against
bot availability only in the sense that the game is unplayable for everyone
anyway. The budget that matters is **time-to-resume** — detect → PR → build
→ canary-prove → waves — which the fast lane exists to minimize. Measure it
via the rollout trace (`updater.detect → updater.apply → ci.build →
rollout.bot`, docs/06 §6.4).
