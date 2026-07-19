# Batch 4 — RC-07 dispatch-line state machine — APPLY NOTES

**Project:** `eizcexopcuoycuosittm` (BOONZ SUPA) · **Author:** DARA · **Date:** 2026-07-18
**Migration:** `20260718170000_rc07_dispatch_line_state_machine.sql` (single `BEGIN`/`COMMIT`)
**Rollback:** `rollback/rc07_rollback.sql` (self-contained) + 5 verbatim `*_pre.sql` pre-images.

Applies **after** Batch 0/1/2 (already applied 2026-07-18). All bodies below were read
**live** from `pg_get_functiondef` on 2026-07-18; edits are minimal-diff / byte-faithful
except the marked RC-07 blocks. DARA did **not** apply or write anything.

---

## 0. Root cause (confirmed against live bodies) & what each fix does

| # | Object | Live defect (line refs = pre-image `rollback/*_pre.sql`) | Fix |
|---|--------|----------------------------------------------------------|-----|
| 1 | `receive_dispatch_line` | Only guard is `item_added` (pre L28). No packed/picked_up precondition → any line force-received; final `UPDATE` flips `packed/picked_up/dispatched` (pre L~92). Overfill branch debits a **single** Active row via `LIMIT 1`, and if no row has `>= v_overfill` the subquery is NULL → `WHERE wh_inventory_id = NULL` → **silent no-op** (pre, overfill block). | Add `p_override boolean`/`p_override_reason text`. State-machine precondition (fill path only) requiring `packed AND picked_up` OR audited override — **gated behind `refill_qa.flag('rc07_receive_gate')` (default `off`)**. Overfill now debits **specific FEFO batch(es)** via canonical `wh_fefo_for_line` (multi-batch) and **RAISEs** if the warehouse can't cover it. `pack_outcome` set consistent (`partial` when filled<planned). |
| 2 | `edit_dispatch_qty` | Only guard is `item_added` (pre L27-29). Editing a **packed** line changes `quantity` without touching `filled_quantity`/`pack_outcome` → "packed 2 / filled 1". | Block when `packed=true` (Cody's "block on packed"); keep `item_added` guard. |
| 3 | `return_dispatch_line` | Never reads `is_m2m` → returning an M2M leg mints WH stock. Raw `EXCEPTION` on terminal/settled legs (pre L~24-40). Remove path inserts `REMOVE-RETURN` rows instead of reactivating origin. Leaves `pack_outcome='packed'` after zeroing `filled_quantity`. | Structured `jsonb` refusal for M2M legs (points to sibling via `m2m_transfer_id`) and for terminal legs. Prefer **reactivating** `from_wh_inventory_id`. Stamp `pack_outcome='returned'`. |
| 4 | `repack_machine` | Step 3 calls `push_plan_to_dispatch(p_machine_name, v_target_date)` = `(text,date)` but the live signature is `(date,text)` → never resolves → **0 rows pushed ever**; unwrapped so it aborts repack (pre, Step 3). | Fix arg order → `push_plan_to_dispatch(v_target_date, p_machine_name)`; wrap in `BEGIN/EXCEPTION` returning a structured error; skip M2M legs in Step 1. |
| 5 | `edit_dispatch_product` (via trigger) | `protect_packed_dispatch_row` blocks `boonz_product_id`/`pod_product_id` changes when `OLD.packed=true`; `edit_dispatch_product` requires `picked_up` (⇒ packed) → **0 product edits ever**. `edit_dispatch_product` body itself is correct (FIX D2 shelf-binding intact) and is **not modified**. | Exempt `current_setting('app.rpc_name')='edit_dispatch_product'` for product/pod fields in the trigger; identity fields (machine/shelf/date) stay protected. |
| 6 | Multi-batch FEFO fill | `pack_dispatch_line` auto-substitution binds ONE `v_sub_id` with `warehouse_stock >= qty` (single batch). Multi-batch fills already work when the **caller** supplies multiple `p_picks` (child-row mechanism). | In-scope here: `receive` overfill now spans batches via `wh_fefo_for_line`. Pack auto-substitution multi-batch spanning = **Deferral D1** (see §7). |

---

## 1. PRE-APPLY md5 gate (read-only — abort on any mismatch)

```sql
SELECT p.proname, p.oid::regprocedure::text AS sig, md5(pg_get_functiondef(p.oid)) AS md5
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN
 ('receive_dispatch_line','return_dispatch_line','edit_dispatch_qty',
  'repack_machine','protect_packed_dispatch_row')
ORDER BY 1;
```
**Expected (must match exactly, else STOP and re-pull):**

| object | md5(pg_get_functiondef) |
|--------|--------------------------|
| `receive_dispatch_line(uuid,numeric,uuid,jsonb)`    | `780e34d8c4c436ea8d9d9c7df85efcbb` |
| `return_dispatch_line(uuid,text,uuid,jsonb)`        | `11d697af27f182d6b15b81cc4547a4e8` |
| `edit_dispatch_qty(uuid,numeric,text,text,text)`    | `e9f99a0dd72c6504539acf186d542748` |
| `repack_machine(text,date,text)`                    | `e6a7d13f41e5876bf5dacd9f9eee0447` |
| `protect_packed_dispatch_row()`                     | `42217e9fde5538995739ca9646c2e4f2` |

**Dependency pre-checks (all read-only):**
```sql
-- push signature must be (date,text) — the arg-order fix depends on it
SELECT to_regprocedure('public.push_plan_to_dispatch(date,text)') IS NOT NULL AS push_ok;      -- true
-- canonical FEFO helper exists (RC-08-A, batch 1)
SELECT to_regprocedure('public.wh_fefo_for_line(uuid,uuid,date,numeric,uuid[])') IS NOT NULL AS fefo_ok; -- true
-- receive has exactly one overload (safe to DROP+CREATE) and no non-normal dependents
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='receive_dispatch_line';                                -- 1
-- enum + flag infra present
SELECT enumlabel FROM pg_enum WHERE enumtypid='public.pack_outcome_enum'::regtype ORDER BY 1;   -- packed/partial/not_filled/packed_transferred (no 'returned' yet)
SELECT to_regclass('refill_qa.feature_flag') IS NOT NULL AS flag_tbl_ok;                        -- true
```
**Timing (B4):** off-peak only. Not during the 20:00 Dubai engine and not during a field
packing window (`receive`/`return` briefly `DROP`/`CREATE`).

---

## 2. APPLY

Single file, single transaction:
```
20260718170000_rc07_dispatch_line_state_machine.sql
```
Order inside the file: (1) `ALTER TYPE … ADD VALUE 'returned'`, (2) seed flag `off`,
(3) `receive` DROP+CREATE+GRANT, (4) `edit_dispatch_qty`, (5) `return`, (6) `repack`,
(7) `protect_packed_dispatch_row`.

> **Enum caveat.** `ALTER TYPE … ADD VALUE 'returned'` and `return_dispatch_line`
> (which references `'returned'::pack_outcome_enum`) are in the same transaction. This is
> safe: plpgsql function bodies are planned lazily at first **runtime** (post-commit), not
> at `CREATE`, so no "unsafe use of new value" is raised. If your apply tool ever objects,
> run the single `ALTER TYPE` line first as its own transaction, then apply the rest.

**Post-DROP note:** `receive_dispatch_line` gains two trailing DEFAULTed params
`(…, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL)`. All existing
2-arg (`receive_all_dispatches_for_machine`) and 4-arg callers resolve unchanged. ACL is
re-granted (PUBLIC EXECUTE is implicit; `anon/authenticated/service_role` explicit).

---

## 3. POST-APPLY verification (read-only; no writes, no engine run)

```sql
-- 3a. new signatures / bodies
SELECT to_regprocedure('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)') IS NOT NULL AS receive_6arg; -- true
SELECT 'returned' = ANY(enum_range(NULL::public.pack_outcome_enum)::text[]) AS enum_has_returned;                          -- true
SELECT (pg_get_functiondef('public.repack_machine(text,date,text)'::regprocedure)
        LIKE '%push_plan_to_dispatch(v_target_date, p_machine_name)%') AS repack_argfix;                                    -- true
SELECT (pg_get_functiondef('public.edit_dispatch_qty(uuid,numeric,text,text,text)'::regprocedure)
        LIKE '%already PACKED%') AS editqty_block;                                                                          -- true
SELECT (pg_get_functiondef('public.protect_packed_dispatch_row()'::regprocedure)
        LIKE '%edit_dispatch_product%') AS trigger_exempt;                                                                  -- true
SELECT refill_qa.flag('rc07_receive_gate') AS gate;                                                                        -- 'off'

-- 3b. the classes RC-07 targets — BEFORE any backfill (baseline snapshot, live 2026-07-18):
--   received Refill/Add non-M2M lines that were never packed+picked_up : 20680
--   packed & filled_quantity < quantity                                :    33
--   packed-short but pack_outcome <> 'partial'                          :    33
--   returned rows still stamped pack_outcome='packed'                  :    98
SELECT 'packed_short'      AS metric, count(*) FROM public.refill_dispatching
 WHERE packed AND NOT returned AND NOT item_added AND filled_quantity IS NOT NULL AND filled_quantity < quantity
UNION ALL
SELECT 'returned_stamped_packed', count(*) FROM public.refill_dispatching
 WHERE returned AND pack_outcome::text='packed';

-- 3c. DRY behaviour check of the new receive gate — DESCRIBE ONLY, do NOT execute (it writes).
--   With the flag 'on', receiving an unpacked fill line must be refused:
--     SELECT public.receive_dispatch_line(<dispatch_id of a Refill line with packed=false>, 1);
--   EXPECTED: RAISE 'receive_dispatch_line: dispatch … is not in a receivable state (packed=f, picked_up=f) …'.
--   Passing p_override:=true, p_override_reason:='<why>' force-receives (audited).
--   Pick a candidate WITHOUT running it:
SELECT dispatch_id, action, packed, picked_up, quantity
FROM public.refill_dispatching
WHERE action IN ('Refill','Add New','Add') AND COALESCE(is_m2m,false)=false
  AND NOT (COALESCE(packed,false) AND COALESCE(picked_up,false))
  AND item_added=false AND COALESCE(cancelled,false)=false
ORDER BY created_at DESC LIMIT 5;
```

---

## 4. ROLLOUT of the receive state-gate (needs FE coordination — Batch 3)

The precondition installs **inert** (`rc07_receive_gate='off'`) so apply is non-breaking
against the 20,680-row historical pattern where `receive` was used as the single
confirmation step. Flip to enforcing only **after** the field flow reliably calls
`pack_dispatch_line` → pickup → `receive` (Stax/FE, Batch 3):

```sql
-- ENABLE (writes one flag row — do under CS sign-off, off-peak):
UPDATE refill_qa.feature_flag SET value='on', updated_at=now() WHERE flag='rc07_receive_gate';
-- DISABLE / instant kill-switch:
UPDATE refill_qa.feature_flag SET value='off', updated_at=now() WHERE flag='rc07_receive_gate';
```
While `off`, the always-on improvements still apply: FEFO multi-batch overfill debit
(+RAISE instead of silent no-op) and `pack_outcome` consistency on receive.

---

## 5. One-time BACKFILL plan (OPTIONAL — flagged, run separately, off-peak)

Not part of the migration. Apply only with CS sign-off; each is idempotent.

```sql
-- B1. packed-but-short lines → 'partial' (live count 33). Aligns pack_outcome with reality.
UPDATE public.refill_dispatching
   SET pack_outcome='partial'
 WHERE packed AND NOT returned AND NOT item_added
   AND filled_quantity IS NOT NULL AND filled_quantity < quantity
   AND COALESCE(pack_outcome::text,'') <> 'partial';

-- B2. returned rows still stamped 'packed' → 'returned' (live count 98). Requires the enum
--     value from this migration to be committed first.
UPDATE public.refill_dispatching
   SET pack_outcome='returned'
 WHERE returned AND filled_quantity=0 AND pack_outcome::text='packed';
```
> These touch `refill_dispatching`, guarded by `protect_packed_dispatch_row`. That trigger
> only blocks identity fields (product/pod/machine/shelf/date) on packed rows — `pack_outcome`
> is not protected — so the backfill passes. Run inside the canonical write context if your
> environment requires `app.via_rpc` (set `app.rpc_name='rc07_backfill'`).
> The 20,680 historical never-packed receipts are **not** rewritten (terminal, `item_added=true`);
> they are recorded as the baseline in §3b for audit.

---

## 6. ROLLBACK

`rollback/rc07_rollback.sql` (self-contained, single tx): drops the 6-arg `receive`,
restores the 4-arg pre-image + ACL, and `CREATE OR REPLACE`s the other four from verbatim
pre-images. Verify restoration with the §1 md5 gate (values must return to the table above).

Irreversible remnants (harmless): the `pack_outcome_enum` value `'returned'` cannot be
dropped, and the `rc07_receive_gate` flag row remains (value `off`). **Before** rolling back,
relabel any live `pack_outcome='returned'` rows (the pre-body never sets that value):
```sql
UPDATE public.refill_dispatching SET pack_outcome='packed'
 WHERE returned=true AND pack_outcome::text='returned';
```

---

## 7. NAMED DEFERRALS (scoped out of Batch 4)

- **D1 — pack multi-batch auto-substitution.** `pack_dispatch_line`'s substitute lookup
  still requires one batch to cover the full pick qty. Design: replace the single
  `v_sub_id` select with a `wh_fefo_for_line(machine, bpid, plan_date, qty, [v_wh])` loop
  emitting one resolved pick per batch (the child-row `INSERT` path already supports N
  picks). Deferred because `pack_dispatch_line` is the hot field path and is **not** in
  Batch 4's modify set. Spec it as its own migration + field test.
- **D2 — callers must branch on `status='refused'`.** `return_dispatch_line` now returns a
  structured refusal (jsonb) for M2M/terminal legs instead of raising. FE and the wrapper
  RPCs (`return_all_dispatches_for_machine`, `eod_auto_release_unpicked`,
  `mark_internal_transfer`, `driver_confirm_remove`) should read `->>'status'` rather than
  rely on an exception. Stax/FE, Batch 3. (Existing callers that ignore the return value are
  safe — they simply no longer mint phantom stock.)
- **D3 — enable `rc07_receive_gate`.** Requires the field flow to always pack→pickup→receive
  (Stax/FE). Until then the gate stays `off`; see §4.
- **D4 — surface `app.receive_override_reason`.** The override reason is written into the
  write-context / `mutation_reason`; a report over overridden receives (audit view) is a
  nice-to-have follow-up.
- **D5 — repack partial-state recovery.** On a wrapped push failure `repack_machine` now
  returns a structured error while the Step-1 returns and Step-2 plan-resets stand (no full
  rollback). Re-running `repack_machine` is idempotent and completes the push; document for
  operators.
