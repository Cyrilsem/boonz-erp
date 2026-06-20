# PRD-040 Track D — Refill v4 Swap Phase-3 Enable Runbook

**Status:** Runbook only. **This document does NOT flip `swaps_enabled`.** The flip is an explicit, CS-executed operational step. `swaps_enabled` is `false` in prod today and stays false until CS runs the steps below.
**Owner:** CS. **Supabase:** eizcexopcuoycuosittm. **Depends on:** PRD-039 (`engine_swap_pod` v13_value_model_broad live, Pass-3 a no-op while disabled).

## 0. What this enables

`engine_swap_pod` Pass-3 (the value-model swap) is fully built and replay-green but **gated off** by the kill switch. Enabling is a supervised, reversible, per-machine rollout: turn it on for one machine, review the proposals it emits on `/refill` for several clean cycles, then widen. No schema change, no code change. Rollback is instant (flag back to false).

## 1. The flag (how it works)

`swaps_enabled` is a key/value row in `refill_settings` (`setting_key text`, `setting_value jsonb`), NOT a column. The engine resolves, per machine:

```
COALESCE(
  (SELECT setting_value FROM refill_settings WHERE setting_key = 'swaps_enabled:' || machine_id),  -- per-machine override
  (SELECT setting_value FROM refill_settings WHERE setting_key = 'swaps_enabled'),                  -- global default
  'true'::jsonb
) = 'false'::jsonb   -> machine is in _swaps_disabled_machines -> 0 Pass-3 swaps for it
```

So a **per-machine enable** = insert/update `swaps_enabled:<machine_id>` = `true`, while the **global** `swaps_enabled` stays `false`. Only the named machine(s) get Pass-3 proposals; the rest stay no-op. This is the safe staged path.

Writing the flag goes through the settings write path (do NOT hand-edit other rows). Per-machine enable, one machine:

```sql
-- ENABLE one machine (CS-run, supervised). Replace <machine_id>.
INSERT INTO refill_settings (setting_key, setting_value, updated_by)
VALUES ('swaps_enabled:<machine_id>', 'true'::jsonb, (SELECT id FROM user_profiles WHERE role='operator_admin' LIMIT 1))
ON CONFLICT (setting_key) DO UPDATE SET setting_value='true'::jsonb, updated_at=now(), updated_by=EXCLUDED.updated_by;
```

## 2. Pre-enable checklist (run read-only, all must hold)

1. `engine_swap_pod` engine_version = `v13_value_model_broad`. `engine_add_pod` = v18 (frozen).
2. Global `swaps_enabled` = `false` (stays false throughout this rollout).
3. The target machine is `picked`+`confirmed` for the plan_date and gate-clean (no approved `refill_plan_output` for the date) — Pass-3 only runs on gate-clean machines.
4. Track B items that change the value model (B3 margin source) are EITHER not yet applied OR applied-and-replayed-green. Do not enable mid-B3.

## 3. Staged rollout

| Stage | Scope                                                                  | Gate to advance                                   |
| ----- | ---------------------------------------------------------------------- | ------------------------------------------------- |
| 0     | none (global false)                                                    | baseline; confirm 0 Pass-3 swaps fleet-wide       |
| 1     | 1 machine (low-risk, high-traffic, well-mapped)                        | **N=3** consecutive clean cycles (see review log) |
| 2     | 3 machines (add 2 of different venue types)                            | N=3 clean cycles each                             |
| 3     | 1 venue group (e.g. ADDMIND or one office cluster)                     | N=3 clean cycles, zero guardrail violations       |
| 4     | fleet (flip global `swaps_enabled`=true; remove per-machine overrides) | CS sign-off                                       |

"Clean cycle" = the swap proposals on `/refill` for that machine are reviewed and every one is: coexistence-clean, non-TCCC at ADDMIND/VOX, in WH stock, value-justified (`v_candidate >= v_keep x 1.15`), unique per machine, within rate limits (<=2/machine, fleet <=10), and homogenisation-capped (<=K machines/product). Any violation = STOP, do not advance, log it.

## 4. Daily review log (one row per supervised cycle)

Keep at `docs/prds/PRD-040-SWAP-REVIEW-LOG.md` (create on first enable). Columns:

| plan_date | machine | n_proposals | accepted | rejected (+reason) | guardrail violations | reviewer | verdict (advance/hold/rollback) |
| --------- | ------- | ----------- | -------- | ------------------ | -------------------- | -------- | ------------------------------- |

Reviewer reads each proposal's `pod_swaps.reasoning` (`source='value_model_swap_broad'`, `v_keep`, `v_candidate`, `cap`, `displaced_pod_product_id`). Rejections feed `refill_edit_signals` (3x rejected -> auto-suppressed, already wired).

## 5. Tunables to revisit during supervised cycles (PRD-039 seeds)

These are hard-coded in `engine_swap_pod` v13; changing them is a forward `CREATE OR REPLACE` (Cody-verdicted), not a flag. Watch for:

| Tunable                | Seed | Watch for                                                             | If wrong                                             |
| ---------------------- | ---- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| `v_cand_min_stock`     | 3    | swaps proposing products with too-thin WH stock (dispatch can't fill) | raise to 5-8                                         |
| `v_top_n`              | 10   | greedy assignment leaving value on the table (rare)                   | raise, or escalate to Hungarian (PRD-039 WS-C note)  |
| `v_K` (homogenisation) | 3    | the same product flooding too many machines/cycle                     | lower to 2; or raise if fleet convergence is desired |
| `v_theta`              | 0.15 | too-marginal swaps (churn) or too-few swaps                           | raise for fewer/stronger swaps                       |

Log observed values vs seeds in the review log; propose a tuned `CREATE OR REPLACE` only after >=2 venue types have data.

## 6. Rollback (instant, no schema change)

```sql
-- ROLLBACK one machine
UPDATE refill_settings SET setting_value='false'::jsonb, updated_at=now() WHERE setting_key='swaps_enabled:<machine_id>';
-- ROLLBACK everything (global already false; just clear overrides)
DELETE FROM refill_settings WHERE setting_key LIKE 'swaps_enabled:%';
```

Next engine run reverts that machine to 0 Pass-3 swaps. Already-emitted `pod_swaps` for a future plan_date are removed by the engine's start-of-run DELETE on re-run, or can be left (they are proposals, not executed until the plan is approved + dispatched). No dispatched swap is undone by the flag — if a bad swap already dispatched, handle via the normal return/convert path.

## 7. Do NOT

- Do not flip the **global** `swaps_enabled` to true until Stage 4 (fleet sign-off).
- Do not enable a machine that is mid-plan (approved `refill_plan_output` exists) — wait for a gate-clean date.
- Do not change tunables and enable in the same cycle (confound the review signal).
- Do not skip the review log — the N-clean-cycles gate is the whole safety mechanism.

## Parked / cross-ref

- 70/30 core-flex enforcement = **PRD-038** (separate).
- Phase-3 fleet enable is pending these supervised cycles; this runbook is the procedure, not the execution.
