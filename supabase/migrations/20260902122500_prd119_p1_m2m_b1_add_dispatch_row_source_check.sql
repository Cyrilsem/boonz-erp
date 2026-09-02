-- PRD-119 P1 / PRD-116-item-B follow-up, piece B1 (root cause). add_dispatch_row set
-- is_m2m unconditionally true whenever p_source_kind IN ('m2m','truck_transfer'), with
-- no comparison of p_source_machine_id to the destination p_machine_id — a same-machine
-- shelf-to-shelf move requested with source_kind='m2m' got is_m2m=true, indistinguishable
-- at the row level from a genuine cross-machine transfer.
--
-- Live-state check before patching (this session, 2026-09-02): B2 (classifier fix,
-- is_internal_move_dispatch now checks the PAIRED leg's actual machine via
-- m2m_transfer_id rather than the naive source_machine_id=machine_id check the original
-- follow-up doc proposed) and B3 (wh_approve_remove_receipt / _multivariant guard
-- reorder, internal-move check now first) were ALREADY shipped under a separate PRD-117
-- effort — confirmed via live pg_get_functiondef, both carry "PRD-117 B2"/"PRD-117 B3"
-- markers. All 8 call sites of is_internal_move_dispatch checked; none relies on the old
-- wrong answer, so B2 being live is safe everywhere.
--
-- B1 is the only piece still open. It is no longer load-bearing for approval
-- correctness (the classifier now catches a mistagged row via ground truth regardless),
-- but it is the only fix that stops NEW rows from being mistagged at the write site —
-- without it, every future same-machine transfer keeps needing the classifier to bail
-- it out rather than never being wrong in the first place.
--
-- Cody: approve, Articles 1/4/12 — corrects only the is_m2m value written on INSERT,
-- no role-check change, add_dispatch_row remains the sole writer.
DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='add_dispatch_row' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'a308f960fb533c89425d5b778b4bd5b3' THEN RAISE EXCEPTION 'add_dispatch_row drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def,
    E'p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind IN (\'m2m\',\'truck_transfer\')), true,',
    E'p_source_kind, p_source_warehouse_id, p_source_machine_id, (p_source_kind = \'truck_transfer\' OR (p_source_kind = \'m2m\' AND p_source_machine_id IS DISTINCT FROM p_machine_id)), true,');
  IF v_new = v_def THEN RAISE EXCEPTION 'add_dispatch_row: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
