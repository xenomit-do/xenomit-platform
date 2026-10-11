# Backup/restore drill report — __DRILL__

| | |
|---|---|
| **Date** | __DATE__ |
| **Operator** | __OPERATOR__ |
| **Overall** | **__OVERALL__** |

Targets: see `docs/rpo-rto.md` (RPO = how much data loss is acceptable;
RTO = how long restore may take).

## Artifacts

| Artifact | Size | Note |
|---|---|---|
__ARTIFACTS__

## Timing (measured this run)

| Phase | Duration |
|---|---|
| Backup | __BACKUP_TIME__ |
| Restore | __RESTORE_TIME__ |
| Verify | __VERIFY_TIME__ |

## Point checks

| Result | Check | Detail |
|---|---|---|
__CHECKS__

## RPO / RTO

| | Target | This run |
|---|---|---|
| RPO | see docs/rpo-rto.md | __RPO_ACTUAL__ |
| RTO | see docs/rpo-rto.md | __RTO_ACTUAL__ |

## Notes / deviations

__NOTES__

## Sign-off

- [ ] Artifacts copied to the off-box location (drill artifacts that stay on
      the same disk they protect do not count toward RPO)
- [ ] Failures (if any) tracked to a fix or a runbook update
- [ ] Next drill date pencilled (cadence: docs/rpo-rto.md)
