# PRD-085 Execution Log — Finalize preserve-approved (VERIFIED)

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED (verified, no engine change).**
Family A md5 `8587be9a1f54594f047f0ae6726599bc` — UNCHANGED (only an additive refill_qa
read-only monitor added; no protected migration, so cody not required).

## Verification (the earlier "unguarded overload" concern was a false alarm)
- The live path `engine_finalize_pod(date)` is a **thin delegate** → `engine_finalize_pod(date, NULL::uuid[])`, the machine-scoped overload, which calls `_assert_refill_plan_writable(plan_date, machine_ids)` — approved/locked rows are protected.
- **Functional rollback-on-prod test:** inserted a synthetic `approved` plan row, ran `engine_finalize_pod(date)`, row stayed `approved` ⇒ PASS (PRD-025 defect does not reproduce).
- **Dynamic:** `check_approved_preserved` scoped to recent plan_dates = 0 defect rows. (All-dates = 99 = pre-Refill-v2 historical residue, not a current defect — run the monitor per recent date.)

## Shipped
- `refill_qa.check_approved_preserved(plan_date?)` — read-only regression monitor
  (defect signature: approved_at set + status=draft). The registered referee regression test.

## Envelope
Reversible (drop the monitor fn), flag-not-needed (no behavioural change), Family A
byte-identical, no protected migration. No code change to the engine (verify-only per PRD).

## Status: SHIPPED (verified + regression monitor registered).
