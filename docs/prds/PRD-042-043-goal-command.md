# Claude Code /goal — PRD-042 + PRD-043 (AUTO MODE, run both)

Paste into Claude Code in `boonz-erp`. Runs BOTH PRDs end-to-end without mid-run approvals. They are independent functions, so order does not matter.

```
/goal Build PRD-042 AND PRD-043 in AUTO MODE. Read docs/prds/PRD-042-swap-slot-profile-pools.md and docs/prds/PRD-043-vox-calendar-gate-picker.md (and PRD-040/039/037 + engines/refill/guardrails/*.md) first; build each exactly per its PRD (data, engine change, and the replay test list in its section 4). Supabase eizcexopcuoycuosittm. No em dashes. Forward-only, no edit-in-place, no _v2 fns, no deletes. engine_add_pod FROZEN. PRD-041 is removed/abandoned; do not build it.

AUTO MODE (both PRDs; do not stop for me to edit or approve):
- Take each PRD's recommended choice and CONTINUE; never halt for sign-off.
- Run Dara (design) and Cody (verdict) yourself as automated steps.
- If a piece cannot be completed (missing dep, failing replay, Cody BLOCK, data gap): SKIP just that piece, do NOT apply it, keep going, record it for the final report.
- Apply only GREEN pieces (that PRD's replay all-pass + Cody approve). If a replay fails, skip the apply and report.
- INVARIANTS (never violate, even to finish): refill_settings.swaps_enabled stays false (never flip); engine_add_pod byte-identical; no git push.

PRD-042 (swap engine v5, gated OFF) decisions to apply without asking:
- Use the STARTER lane grouping: bottle={bottle_330,bottle_500,bottle_large}; can={can_250,can_330}; snack_small={bar_standard,pack_gum,date_ball}; bag={bag_snack,bag_large}; boxed={box_biscuit,cake_wrapped}; cup={cup_yogurt}; other={other}. Coverage 14/14; any unmapped physical_type -> other + note.
- slot_pool_curation empty (derived-only). slot_profile_pool PRECOMPUTED nightly via rebuild_slot_profile_pool() + pg_cron BEFORE job 13; run first rebuild.
- engine_swap_pod v14 -> v15_slot_profile (Pass-3 rewrite only; qty_in = profile fill_qty, not candidate cap). swaps_enabled stays false (engine stays a no-op until PRD-040 Track D pilot). Replay SP1-SP6 + R1 per the PRD.

PRD-043 (picker v10 -> v11 VOX calendar gate) decisions to apply without asking:
- NOT flag-gated: applying changes the live 8pm pick (intended fix). Apply only if V1-V6 + R1 all pass; else skip + report.
- Use OPTION B: VOX excluded from normal-day primary pick EXCEPT runway_days < days_until_next_vox_day(p_plan_date) (runway-only predicate), tagged reason 'vox_emergency_offday', still counts vs cap-8. Add the days_until_next_vox_day(date) IMMUTABLE helper. Gate goes in ranked_primary; sibling_ranked unchanged. Replay V1-V6 + R1 per the PRD. On apply, bump the stale picker version note (skill/memory say v8/v9; live v10 -> v11).

APPLY (auto, only green pieces): prod-confirm (042: engine_version=v15_slot_profile + pool fresh; 043: pick_machines_for_refill v11 live). Write docs/prds/PRD-042-EXECUTION-LOG.md and docs/prds/PRD-043-EXECUTION-LOG.md; update CHANGELOG/RPC_REGISTRY/MIGRATIONS. No git push.

FINAL REPORT (always): per PRD - PASS/FAIL table with actual values, applied y/n + timestamp per object, and one ** INCOMPLETE / NEEDS CS ** section listing every piece skipped/assumed/failed/Cody-flagged with the reason. Restate assumptions: 042 starter lane grouping (confirm later); 043 Option B runway-only. swaps_enabled still false; PRD-040 Track D unblocks only after 042 lands.
```
