-- PRD-068 (slice): purge the 9 stale TEST dispatch rows dated >= 2099 ("[S1] refill full-fill test",
-- "[S4] BUG-012 cascade live test") that were still dispatched=true and skewed MAX(dispatch_date)=2099.
-- Pre-authorized (PRD-ALL overnight). Cody verdict 2026-06-30 ✅ (Articles 1,3,12). Applied 2026-06-30.
-- Idempotent: re-run deletes 0. app.via_trigger lets enforce_canonical_dispatch_write treat this as a
-- trusted system cleanup (no bypass log); DELETE is not blocked by protect_packed_dispatch_immutability
-- (BEFORE UPDATE only); tg_audit_refill_dispatching AFTER DELETE records the removal. Verified after:
-- 0 rows >= 2099, MAX(dispatch_date)=2026-07-15, 0 orphaned 2099 pod rows.
-- (The rest of PRD-068 - conservation reconcile-to-driver-truth, not_filled fix, re-assert hook,
-- monitor cron - is skip+logged in PRD-ALL-overnight-EXECUTION-LOG.md, not applied this run.)

SET LOCAL app.via_trigger = 'true';
DELETE FROM public.refill_dispatching WHERE dispatch_date >= '2099-01-01';
