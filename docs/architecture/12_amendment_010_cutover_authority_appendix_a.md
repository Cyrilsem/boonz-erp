# Amendment 010 — Engine cutover authority: Appendix A addition

**Date:** 2026-08-08 (PRD-110 leg 160, DR-1)
**Articles invoked:** 15 (declare invariants / Appendix A scope); references Articles 1, 2, 3, 4, 5, 7, 8, 14
**Status:** proposed by Dara, reviewed by Cody (⚠️ approve with revisions — all three shipped), applied

## Summary

PRD-110 DR-1 adds the Phase 5 per-cluster cutover unit: two new tables, one canonical gate view and
four functions. This amendment reconciles Appendix A and records the constitutional posture, per the
pattern of Amendments 003 and 009.

## Proposed Appendix A addition

Add **`engine_cutover_authority_v3`** to the protected entity list.

**Why it belongs there and why the bar is not arguable.** Appendix A protects the entities whose
corruption changes what the business physically does. This table decides **which brain plans the
fleet**. A single unauthorized UPDATE to one row either (a) halts the entire nightly refill plan, or
(b) once DR-1b ships, hands a cluster's planning to a different engine. Nothing currently on the list
has a larger blast radius per row, and the table holds exactly 10 rows.

`engine_cutover_audit_v3` is **not** proposed for Appendix A. It is an append-only ledger with no
consumer that changes behaviour, in the same class as `monitoring_alerts` under Amendment 009. It is
covered by Article 7 (RLS UPDATE/DELETE blocked) rather than by Appendix A.

## Constitutional posture as shipped

| Article | Posture                                                                                                                                                                                                |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1       | Exactly two canonical writers: `flip_cluster_to_v3_v3`, `revert_cluster_to_v19_v3`. No other path writes the registry.                                                                                 |
| 2       | RLS enabled on both tables.                                                                                                                                                                            |
| 3       | ⛔ See S-308 below. `authenticated` is read-only on both tables **after an explicit REVOKE**, not by default.                                                                                          |
| 4       | Both writers are SECURITY DEFINER, pin `search_path`, set `app.via_rpc` + `app.rpc_name`, validate inputs (NULL + a ≥10-char reason) and validate role against `user_profiles`.                        |
| 5       | `authoritative_engine` is a status column with one RPC per direction. No raw UPDATE reaches it.                                                                                                        |
| 7       | `engine_cutover_audit_v3` blocks UPDATE and DELETE at the policy layer (`USING (false)`).                                                                                                              |
| 8       | `tg_audit_engine_cutover_authority_v3` (AFTER INSERT/UPDATE/DELETE) mints a `write_audit_log` row via the generic `audit_log_write('cluster_key')`.                                                    |
| 14      | Neither table materializes a query a view could compute — one holds decision state, the other is an append-only ledger. **No ADR required** (same ground `ADR-shadow-plan-tables.md` already cleared). |
| 16      | `v_cutover_readiness_v3` is the canonical object for "is a cluster ready for cutover", registered in `METRICS_REGISTRY.md`.                                                                            |

## ⛔⛔ S-308 — a general exposure this unit surfaced, worth an amendment on its own

Fixture 74 seq 8/9 went **red against a migration that had already stripped `anon` and granted
`authenticated` nothing but SELECT**. The cause:

> **A Supabase DEFAULT PRIVILEGE grants `authenticated` DELETE / INSERT / REFERENCES / SELECT /
> TRIGGER / TRUNCATE / UPDATE on EVERY new table created in `public`.**

Consequences that generalize well beyond DR-1:

- A migration that only **adds** `GRANT SELECT ... TO authenticated` is a **no-op**. The write verbs
  were already there.
- `REVOKE ALL ... FROM anon, PUBLIC` — the S-268 idiom — **does not touch** a grant held by
  `authenticated`. S-268 and S-308 are different holes and closing one does not close the other.
- Article 3 compliance for any NEW table therefore requires an **explicit REVOKE from
  `authenticated`**, and it must be **asserted**, not assumed.

In DR-1's case this was never a live hole: the registry's `FOR UPDATE/DELETE USING (false)` policies
refused the writes regardless. But that means the only thing standing between `authenticated` and a
direct cutover flip was a policy that happened to be written. Fixed in `20260808217000`, with the
grant level asserted by fixture 74 seq 8/9 so it cannot regress silently.

⭐ **Recommendation for the next Constitution revision:** Article 3's checklist should state that a
new table in `public` is **born writable by `authenticated`**, and that every migration creating one
must carry the REVOKE plus a post-image proof. Every table this project has added since the Supabase
defaults were set is worth auditing on the same query.

## Ratification

1. `engine_cutover_authority_v3` added to Appendix A.
2. Article 3 checklist gains the S-308 note above (pending the next Constitution revision).
3. `RPC_REGISTRY.md` and `METRICS_REGISTRY.md` updated in the same commit.
