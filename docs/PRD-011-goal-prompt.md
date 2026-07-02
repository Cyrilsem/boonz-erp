# /goal prompt for Claude Code CLI

Run from `boonz-erp` root. Read `docs/PRD-011-fe-refill-commit-fix.md` for full context.

```
/goal Fix 4 bugs in RefillPlanningTab.tsx + 1 backend engine bug per docs/PRD-011-fe-refill-commit-fix.md.

Bug 1 (P0) — commitDraft passes selectedDate to RPCs but the loaded draft may have a different plan_date. Add state `draftPlanDate`, set it from loadDraft response, use it in commitDraft instead of selectedDate. Disable Commit when null. Show yellow banner if selectedDate !== draftPlanDate.

Bug 2 (P0) — editedQty and removed are client-side only. Before Gate 1 approve in commitDraft, add Step 0: loop editedQty entries calling supabase.rpc('edit_pod_refill_row') with draftPlanDate + row identifiers + newQty. Loop removed calling same RPC with qty=0. Abort on error.

Bug 3 (P1) — Restore button for superseded rows only toggles client state. Create migration with RPC restore_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action) that UPDATEs status='superseded' to 'draft'. Wire FE Restore button to call it.

Bug 5 (P1) — engine_finalize_pod generates M2W/Remove without checking if a replacement fills the shelf. Add post-processing: for each M2W row, check if same (plan_date, machine_id, shelf_id) has an Add New/Refill/Swap In row. If not and shelf not tagged for decommission, set status='superseded' with reasoning='auto_suppressed: no replacement' and add to capacity_mismatch_warnings.

Skip Bug 4 (cron diagnostic, not a code change). See PRD for acceptance criteria.
```
