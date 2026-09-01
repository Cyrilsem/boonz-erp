-- PRD-118 item H audit (Addendum 2 §H.3): wh_fefo_for_line's is_satisfiable/
-- running_pickable are AGGREGATE checks across the whole candidate set (does the total
-- pickable pool, net of committed-elsewhere, cover the line at all). push_plan_to_dispatch's
-- pin logic bound the FULL line quantity to pick_rank=1's single batch on that basis —
-- correct only when that one batch alone happens to be big enough, which is not what
-- is_satisfiable/running_pickable actually assert. This is the root cause of "Ice Tea
-- x10 pinned to a 2-unit batch" (01 Sep).
--
-- Fix: require f.net_running >= line.quantity instead of the aggregate check. net_running
-- is wh_fefo_for_line's own per-row cumulative-pickable-minus-committed column — at
-- pick_rank=1 this is exactly "does the earliest batch alone cover the line". A line
-- needing multiple batches is deliberately left unbound here (from_wh_inventory_id
-- stays NULL) for bind_dispatch_fefo (PRD-118 item H, prd118_h1, applied earlier this
-- session) to resolve via its quantity-aware split logic. This is a strictly TIGHTER
-- condition than before — it can only leave more rows unbound, never mis-bind one it
-- previously would have bound correctly.
--
-- Verified against md5 63704c7630dc9920da40335260d242a2. Cody: approve, Articles 1/4/12
-- — no new write path, existing writer's own pin condition corrected to match what its
-- own inputs actually assert.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '63704c7630dc9920da40335260d242a2' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def,
$$      WHERE f.is_satisfiable
        AND f.running_pickable > f.committed_elsewhere
      ORDER BY f.pick_rank
      LIMIT 1;$$,
$$      -- PRD-118 item H audit: is_satisfiable/running_pickable are AGGREGATE checks
      -- across the whole candidate set; binding pick_rank=1 wholesale on that basis
      -- let a line's full quantity pin to a single batch too small to cover it (Ice
      -- Tea x10 -> a 2-unit batch, 01 Sep). net_running is the row's OWN cumulative
      -- pickable-minus-committed at that rank — only pin here when the single earliest
      -- batch alone (or its cumulative predecessors, if this is not rank 1) already
      -- covers the full line. A genuine multi-batch split is deliberately left unbound
      -- here for bind_dispatch_fefo (PRD-118 item H) to resolve afterward.
      WHERE f.is_satisfiable
        AND f.net_running >= line.quantity
      ORDER BY f.pick_rank
      LIMIT 1;$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'pin WHERE clause not found'; END IF;
  EXECUTE v_new;
END $mig$;
