---
id: PROGRAM-2026-06-01
parent: PROGRAM-2026-05-30
title: Stax FE refactor — close the 13+ direct writers before 2026-06-06 flip
status: Partially-shipped-2026-05-30 (O1 done + 5 of 11 FE writers closed; 6 deferred to PROGRAM-2026-06-01b; D1 flip parked)
severity: P0
reported: 2026-05-30
deadline: 2026-06-05 EOD Dubai (pre-flip soak check on 2026-06-06 morning)
source: PROGRAM-2026-05-30 Phase D audit — `docs/prds/_programs/phase_d_audit/PROGRAM-2026-05-30_phase_d_audit.md`. 13+ FE call sites still write directly to refill_dispatching. On 2026-06-06 the enforcement trigger flips RAISE WARNING → RAISE EXCEPTION; any remaining direct writer will throw and break the field PWA.
routing: [Dara (small), Cody (3 RPCs), Stax (4 file refactors)]
---

# Stax FE refactor — close the 13+ direct writers

This is a **decisions-only PRD** — same pattern as PROGRAM-2026-05-30. Every RPC contract is decided; every file-level refactor mapping is decided. The agent ships without asking architectural questions.

The work is calendar-bound: must be done by 2026-06-05 EOD Dubai so the pre-flip soak query returns zero on 2026-06-06 morning before the trigger flips to RAISE EXCEPTION.

## Outcomes (must all be Done by 2026-06-05 EOD)

1. **O1 — 3 new canonical RPCs live and Cody-approved**: `update_dispatch_comment`, `set_dispatch_include`, `insert_driver_remove_line`.
2. **O2 — 4 FE files refactored**: every direct `.from('refill_dispatching').{insert|update|delete}` replaced with a canonical RPC call.
3. **O3 — pre-flip soak passes**: `SELECT count(*) FROM bypass_violation_log WHERE rpc_name IS NULL AND occurred_at > '2026-06-04'` returns 0.
4. **O4 — 2026-06-06 flip migration ships**: `enforce_canonical_dispatch_write` trigger flips from RAISE WARNING to RAISE EXCEPTION.

## Decisions (no open questions)

### Backend — 3 new RPCs

**Decision A1: `update_dispatch_comment(p_dispatch_id uuid, p_comment text)`**

```sql
CREATE OR REPLACE FUNCTION public.update_dispatch_comment(
  p_dispatch_id uuid,
  p_comment     text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text; v_old_comment text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'update_dispatch_comment: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'update_dispatch_comment', true);

  SELECT comment INTO v_old_comment FROM refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch_id % not found', p_dispatch_id; END IF;

  UPDATE refill_dispatching SET comment = NULLIF(TRIM(p_comment), '')
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id,
    'old_comment', v_old_comment, 'new_comment', NULLIF(TRIM(p_comment), ''));
END $$;
GRANT EXECUTE ON FUNCTION public.update_dispatch_comment(uuid,text) TO authenticated;
```

Used by: `dispatching/[machineId]/page.tsx` lines 624, 669; `trips/[machineId]/page.tsx` line 228 (and possibly 257 depending on payload).

**Decision A2: `set_dispatch_include(p_dispatch_id uuid, p_include boolean)`**

```sql
CREATE OR REPLACE FUNCTION public.set_dispatch_include(
  p_dispatch_id uuid,
  p_include     boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_dispatch_include: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;
  IF p_include IS NULL THEN RAISE EXCEPTION 'p_include required'; END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_dispatch_include', true);

  UPDATE refill_dispatching SET include = p_include WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch_id % not found', p_dispatch_id; END IF;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id, 'include', p_include);
END $$;
GRANT EXECUTE ON FUNCTION public.set_dispatch_include(uuid,boolean) TO authenticated;
```

Used by: `packing/[machineId]/page.tsx` line 1296.

**Decision A3: `insert_driver_remove_line(p_machine_id uuid, p_boonz_product_id uuid, p_pod_product_id uuid, p_shelf_id uuid, p_quantity numeric, p_expiry_date date, p_reason text)`**

Driver inserts a Remove line on the spot (off-plan return). Required ONLY IF `dispatching/[machineId]/page.tsx` line 497 is a driver-initiated insert. The agent must investigate the file's intent first; if line 497 is something else (e.g., admin-only seed), pick the matching RPC.

```sql
CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(
  p_machine_id        uuid,
  p_boonz_product_id  uuid,
  p_pod_product_id    uuid,
  p_shelf_id          uuid,
  p_quantity          numeric,
  p_expiry_date       date,
  p_reason            text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text; v_dispatch_id uuid;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, expiry_date,
     packed, picked_up, dispatched, returned, include, comment)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     CURRENT_DATE, 'Remove', p_quantity, p_expiry_date,
     true, true, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason))
  RETURNING dispatch_id INTO v_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason);
END $$;
GRANT EXECUTE ON FUNCTION public.insert_driver_remove_line(uuid,uuid,uuid,uuid,numeric,date,text) TO authenticated;
```

**Decision A4: Cody review for all 3 RPCs against Articles 1, 3, 4, 8.** Articles 5 (state machine) is N/A; the comment + include + driver-insert paths don't transition state machine columns.

**Decision A5: All 3 ship in ONE migration** named `phaseG_stax_canonical_writers_for_dispatch_fe_refactor`. Single Cody review, single deploy.

### FE — 4 files refactored

**Decision B1 — `src/app/(field)/field/packing/[machineId]/page.tsx`** (highest traffic, do first)

| Line | Current                                                      | Refactor to                                                                                                                                                   |
| ---- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1142 | `.from('refill_dispatching').delete().eq('dispatch_id', id)` | `supabase.rpc('cancel_dispatch_line', { p_dispatch_id: id, p_reason: '...' })`                                                                                |
| 1210 | `.update({ packed: true, filled_quantity: 0 })`              | `supabase.rpc('pack_dispatch_line', { ... with picks=[] for zero pack })`                                                                                     |
| 1268 | `.update({...})` (depends on payload)                        | If payload includes `packed` / `filled_quantity` → `pack_dispatch_line`. If it's a comment edit → `update_dispatch_comment`. Agent: inspect at refactor time. |
| 1296 | `.update({ include: true })`                                 | `supabase.rpc('set_dispatch_include', { p_dispatch_id: id, p_include: true })`                                                                                |

**Decision B2 — `src/app/(field)/field/dispatching/[machineId]/page.tsx`**

| Line | Current                                     | Refactor to                                                                                    |
| ---- | ------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 497  | `.insert({...})`                            | If driver-initiated Remove → `insert_driver_remove_line`. Agent verifies caller context first. |
| 535  | `.delete()`                                 | `cancel_dispatch_line`                                                                         |
| 624  | `.update({ comment: line.comment.trim() })` | `update_dispatch_comment`                                                                      |
| 669  | `.update({ comment: line.comment.trim() })` | `update_dispatch_comment`                                                                      |

**Decision B3 — `src/app/(field)/field/trips/[machineId]/page.tsx`**

| Line | Current                                        | Refactor to                                                       |
| ---- | ---------------------------------------------- | ----------------------------------------------------------------- |
| 228  | `.update({ comment: value.trim() \|\| null })` | `update_dispatch_comment`                                         |
| 257  | `.update({...})` (depends on payload)          | Inspect; likely `update_dispatch_comment` or `pack_dispatch_line` |

**Decision B4 — `src/app/(app)/refill/DailyDispatchingTab.tsx`**

| Line | Current                  | Refactor to                                                                                                                                                        |
| ---- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 299  | `.update(updatePayload)` | Inspect `updatePayload` shape: comment → `update_dispatch_comment`; pack state → `pack_dispatch_line`; M2M flip → `mark_internal_transfer` (already on allow-list) |

**Decision B5 — Refactor order**: B1 packing first (highest traffic, biggest blast radius), then B2 dispatching, then B3 trips, then B4 admin UI. Stax owns end-to-end; each file gets its own commit so blame is clean.

**Decision B6 — Test pattern per file**: after each refactor, manually exercise the affected flow on a staging machine and verify zero new rows in `bypass_violation_log` for that user's session.

### Verification — pre-flip soak

**Decision C1**: 2026-06-05 EOD Dubai: run

```sql
SELECT count(*), array_agg(DISTINCT actor_role) AS roles, MAX(occurred_at) AS most_recent
FROM bypass_violation_log
WHERE rpc_name IS NULL AND occurred_at > '2026-06-04';
```

Must return `count = 0` (i.e., zero direct writers during the 24-hour soak before the flip).

**Decision C2**: If count > 0 on 2026-06-05 EOD:

- Investigate which file is still firing
- Fix it
- Re-run the soak for 24h
- Defer the flip to 2026-06-08 (or later) if necessary

DO NOT flip the trigger on 2026-06-06 if the soak fails. The flip migration is its own decision; calendar pressure is real but breaking the field PWA is worse.

### Flip migration

**Decision D1**: Only run on or after 2026-06-06 AND after the pre-flip soak passes.

```sql
-- Migration: phaseG_health_bypass_block_flip
CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_via_rpc text; v_rpc_name text; v_actor uuid := auth.uid();
BEGIN
  v_via_rpc  := current_setting('app.via_rpc', true);
  v_rpc_name := current_setting('app.rpc_name', true);

  -- Body unchanged from Phase 1 (allow-list logic) EXCEPT:
  -- replace RAISE WARNING with RAISE EXCEPTION
  IF v_via_rpc IS DISTINCT FROM 'true' OR v_rpc_name NOT IN (
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'update_dispatch_comment','set_dispatch_include','insert_driver_remove_line'
  ) THEN
    INSERT INTO bypass_violation_log (...) VALUES (...);
    RAISE EXCEPTION 'refill_dispatching write rejected: rpc=% via_rpc=% actor=%',
      COALESCE(v_rpc_name, 'NULL'), COALESCE(v_via_rpc, 'NULL'), v_actor
      USING HINT = 'Use one of the allow-listed canonical RPCs.';
  END IF;
  RETURN NEW;
END $$;
```

Note the allow-list now includes the 3 new RPCs from this PRD.

## Hard rules (binding for the agent)

1. **Canonical RPCs only** on protected tables (refill_dispatching is protected).
2. **NO test refactor that introduces a regression**: after each FE file change, verify the affected flow still works on staging before committing.
3. **Cody approval mandatory** on the 3 new RPCs migration.
4. **Stax review mandatory** on every FE diff before commit (this whole PRD is Stax-led; the rule means: don't merge an FE change that doesn't actually replace a direct write).
5. **Do not flip the trigger** until the pre-flip soak query returns 0.
6. **If any FE file's intent is unclear at refactor time** (specifically: `dispatching/page.tsx:497` and `DailyDispatchingTab.tsx:299` where payload shape determines target RPC), the agent READS the surrounding code first to determine intent, then picks the matching RPC. NO guessing.
7. **All commits Cody-reviewed** for Article 3 compliance.

## Acceptance criteria

- O1: `SELECT count(*) FROM pg_proc WHERE proname IN ('update_dispatch_comment','set_dispatch_include','insert_driver_remove_line') AND pronamespace = 'public'::regnamespace` returns 3.
- O2: `git grep -E "\\.from\\('refill_dispatching'\\)\\.(insert|update|delete|upsert)" src/` returns 0 matches.
- O3: pre-flip soak query returns count = 0 on 2026-06-05 EOD.
- O4: On 2026-06-06 (or later when soak passes), trigger raises EXCEPTION on direct writes. Verify: try a direct UPDATE in a test transaction, expect rejection.

## /goal command

```
/goal docs/prds/_programs/PROGRAM-2026-06-01-stax-fe-refactor.md

Execute Decisions A1-A5 (backend migration), then B1-B6 (FE refactors in
order), then halt for the 2026-06-05 pre-flip soak. The flip migration
(D1) ships separately ONLY after the soak passes.

Hard rules (restated):
- Cody approval on the 3-RPC migration before apply.
- Refactor FE files in the B1-B6 order: packing first.
- After each file, verify zero new bypass_violation_log rows for the test
  session before committing.
- For lines where the target RPC depends on payload shape (B1 line 1268,
  B2 line 497, B3 line 257, B4 line 299), READ the surrounding code to
  determine intent, then pick the matching RPC. NO guessing.
- Do NOT run the D1 flip migration until the pre-flip soak (Decision C1)
  returns count = 0.
- If the soak fails on 2026-06-05, defer the flip and continue refactor
  work until it passes.
- All commits must pass tsc/build/lint.

End state: all 13+ FE direct writers replaced with canonical RPCs, pre-flip
soak passes, trigger ready to flip on 2026-06-06.
```

## Linked PRDs

- [[PROGRAM-2026-05-30-loophole-engine]] — parent program; F1/F2 closure that this PRD finishes
- [[phase_d_audit/PROGRAM-2026-05-30_phase_d_audit]] — the audit that surfaced the 13+ direct writers

## Linked memory

- [[feedback_dispatching_action_casing]] — Title Case action enforcement; new `insert_driver_remove_line` must use 'Remove' not 'REMOVE'
- [[feedback_no_destructive_changes]] — `cancel_dispatch_line` is the canonical "soft delete" path; never use raw DELETE
