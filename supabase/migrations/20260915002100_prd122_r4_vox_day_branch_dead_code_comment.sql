-- ONE-LOOP-2 Block A0 (2): documentation only, no behaviour change.
--
-- The VOX-day branch inside pick_machines_for_refill(p_plan_date, p_max_total,
-- p_max_siblings) is unreachable. The 3 partner_filled machines have zero
-- rows in v_machine_priority, so svc_track='vox' matches nothing, bool_and
-- over the empty set is NULL, COALESCE(...,true) makes v_vox_all_equip true,
-- and "IF v_is_vox_day AND NOT v_vox_all_equip" never fires. vox_centroid,
-- the hero_runway_days off-day gate, the vox_emergency_offday tag and its
-- ORDER BY branch are all dead code. MCC clustering still works, via
-- sibling_ranked on r_cluster = 'VOX' capped at p_max_siblings. Removal is a
-- separate later PRD; this comment is documentation only. Carry this comment
-- forward verbatim into v12 when Block B rebuilds this function.
COMMENT ON FUNCTION public.pick_machines_for_refill(date, integer, integer) IS
'PRD-122 dead-code note (verified 2026-09-15): the VOX-day branch (vox_centroid, hero_runway_days off-day gate, vox_emergency_offday tag, its ORDER BY) is unreachable, because the 3 partner_filled machines have zero rows in v_machine_priority (svc_track=''vox'' matches nothing, bool_and over the empty set is NULL, COALESCE(...,true) makes v_vox_all_equip true, so "IF v_is_vox_day AND NOT v_vox_all_equip" never fires). MCC clustering still works via sibling_ranked on r_cluster=''VOX'' capped at p_max_siblings. Removal is a separate later PRD.';
