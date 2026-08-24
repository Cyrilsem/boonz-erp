-- PRD-116a: the PRD-053 conservation guard in push_plan_to_dispatch counted SUPERSEDED
-- pod_refill_plan REMOVE/M2W rows (which by design have no approved children) and stop-shipped
-- healthy plans. 3rd occurrence 2026-08-23 (5 of 6 machines blocked; leaking_instructions ==
-- superseded M2W count per machine, exactly). Fix: the parent side of the comparison only
-- considers rows that are still live. Verbatim body, one predicate added. Cody OK 1,4,8,12.
-- Applied to prod via MCP 2026-08-23 21:56 UTC. md5 guard 487f33107819ce8335251e235ac7405e.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '487f33107819ce8335251e235ac7405e' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
  v_new := replace(v_def,
    $$AND prp.action IN ('REMOVE','M2W') AND prp.qty > 0$$,
    $$AND prp.action IN ('REMOVE','M2W') AND prp.qty > 0
      AND prp.status <> 'superseded'  -- PRD-116a: superseded rows have no children by design$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'target predicate not found'; END IF;
  EXECUTE v_new;
END $mig$;
