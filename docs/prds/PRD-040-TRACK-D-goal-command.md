# Claude Code /goal — PRD-040 Track D (Phase-3 supervised swap enable)

Paste into Claude Code in `boonz-erp` ONLY when ready to begin supervised swap enablement. This FLIPS live behaviour (the engine starts emitting swap proposals) for the named machines. Proposals still require FE approval to dispatch.

```
/goal Execute PRD-040 Track D (Phase-3 supervised enable) per docs/prds/PRD-040-PHASE3-ENABLE-RUNBOOK.md. Read it first. Supabase eizcexopcuoycuosittm. No em dashes. This is the ONLY goal allowed to change swaps_enabled, and ONLY per-machine for machines CS names. NEVER set the global swaps_enabled true. Do not change engine_add_pod / engine_swap_pod / stitch.

PILOT MACHINES: << CS fills in 1-3 official_names here, e.g. ADDMIND-1007-0000-W0 >>. If this list is empty, STOP and ask CS.

STEPS:
1. PRECHECK: confirm engine_swap_pod = v14_landed_cost_margin live, global swaps_enabled='false', engine_add_pod v18. If not, STOP.
2. Cody verdict the per-machine enable WRITE PATH before any write: setting refill_settings key 'swaps_enabled:<machine_id>'='true'. Use the constitutional writer if one exists; if it would be a raw table write, get Cody's explicit nod first (refill_settings is config, not Appendix-A protected, but route cleanly).
3. For each named pilot machine: set 'swaps_enabled:<machine_id>'='true'. Print the before/after of each key. Do NOT touch any other machine or the global key.
4. Set up the daily review query (read-only): pod_swaps WHERE reason='score_swap' AND plan_date = resolve_refill_plan_date() for the pilot machines, joined to product names + v_keep/v_candidate from reasoning. This is what CS reviews on /refill each morning.
5. STOP. Report: which machines enabled, the next plan_date's proposed swaps for them, and the review query. Do NOT expand to more machines.

EXPANSION / ROLLBACK (separate CS calls, not this run):
- Expand only after N clean supervised cycles (CS decides N), by re-running with more pilot names.
- Rollback any machine instantly: set 'swaps_enabled:<machine_id>'='false' (engine returns to no-op for it). No schema change.

HARD RULES
- Per-machine only; global swaps_enabled stays false.
- Engine bodies unchanged.
- Stop after enabling the named pilot set + emitting the review query; never auto-expand.
- Swap proposals are NOT auto-dispatched; CS approves via FE Commit as usual.
```
