# Claude Code /goal Command - PRD-035 (condensed, <4000 chars)

Paste the block into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. Phased; STOP per phase for CS sign-off. Forward-only. No em dashes. Migration FILES only; apply nothing to prod. Phase A runs now (no CS decision); B/D/E stop for the open decisions.

```
/goal Implement PRD-035 (docs/prds/PRD-035-refill-v3-scoring-context-picker.md); read it first. Goal: refill engine resolves pod->in-stock flavor->real pickable stock as first-class, sizes fills by each shelf's RELATIVE score within its machine, exposes session state up front, picks a trip-efficient P1 route with the VOX calendar. Stance is display-only, never a driver.

RULES
- Fetch live bodies (pg_get_functiondef/pg_get_viewdef) before editing; never guess.
- Forward-only migrations (ts prefix), no _v2/edit-in-place. DEFINER writers set app.via_rpc+app.rpc_name, validate role+inputs, hit the audit trigger.
- Protected (refill_plan_output, pod_refill_plan, refill_dispatching, warehouse_inventory): Cody verdict per writer; Dara designs views/cols; Stax wires FE.
- No deletes (supersede only); no qty cut without a per-row diff. Migration FILES only. Per phase: live body + SQL + diff + Cody verdict, then STOP for CS. Log ACs in PRD-035-EXECUTION-LOG.md.

STATE (verified 2026-06-18, do not re-diagnose):
- stitch_pod_to_boonz (live v23) REFILL: is_residual_variant admits a variant only if on_shelf=true (v_pod_inventory_latest) once any mapped variant is on the shelf. If the on-shelf flavor has 0 pickable WH the line drops to 0 boonz; procurement_alerts uses raw split x WH (ignores on_shelf) so it never flags it -> silent 0-fill. Hit Red Bull/Healthy Cola/Hunter for 2026-06-18.
- final_score already compiles stance+global+local (compute_refill_decision). v_wh_pickable excludes quarantined+reserved. velocity in metrics registry (PRD-028). pod_refill_plan draft->approved->stitched, stitch gates 'approved'; reopen_stitched_rows + reset_approved_undispatched exist (PRD-033).

PHASE A (WS-C, HEADLINE, run now, no decision): stitch falls back to an in-stock sibling of the same pod when the on-shelf/ideal flavor has 0 pickable WH (keep qty+visual). Any dropped/substituted line ALWAYS raises a procurement_alert + dispatch note naming the swap; line-builder and alert-builder must agree (no silent 0). Priority: right-qty+right-SKU > right-qty via sibling > empty. Forward CREATE OR REPLACE phaseF_stitch_wh_aware_variant_fallback. Cody mandatory.

PHASE B (WS-A, relative-score fill): compute_refill_decision/engine_add_pod rank shelves by final_score WITHIN the machine; fill scales with rank (top=full, low+empty=low %); drop stance_mult from qty (stance display-only); 0 local sales (u7d=0,v30=0)=no fill. AWAIT CS A1 (rank->fill curve).

PHASE C (WS-D, session readiness): Dara read-only get_refill_session_readiness(plan_date): per in-scope shelf - on-shelf flavor vs pickable WH per flavor (net reservations+quarantine via v_wh_pickable), pod->in-stock-flavor mapping health, onboarding gaps, expiry risk; output can-fill / cant-fill+why.

PHASE D (WS-E, picker): pick_machines_for_refill P1-first + area cluster + pull in P2 co-located sisters. VOX: Wed AM + Fri AM = all VOX + 2-3 non-VOX (focus non-VOX if VOX well-equipped); Saturday = no plan (Fri 8pm cron skips). AWAIT CS E1 cluster key, E2 well-equipped rule, E3 non-VOX pick, E4 sister def.

PHASE E (WS-B, score swap): engine_swap_pod replaces low-rank slot products with higher-projected candidates (find_substitutes_for_shelf) to maximize per-slot return; replaces stance-based triggers. AWAIT CS B1 (relocate vs drop) + B2 (threshold).

CONFIRM per phase: (A) rolled-back replay of 2026-06-18 - 3 heroes resolve >0 via correct/sibling SKU, each substituted line has alert+note, zero silent 0, other machines unchanged; (B) low-score empty fills < top-score shelf, stance no longer affects qty; (C) flags a quarantined+reserved+unmapped case, read-only; (D) Saturday=no plan, VOX day=all-VOX+2-3; (E) swap only when score gap > threshold.
```
