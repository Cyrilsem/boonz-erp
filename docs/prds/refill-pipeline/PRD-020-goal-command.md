# /goal - PRD-020 Complete but Partial packing (FE only, <4000 chars). Paste into Claude Code in boonz-erp.

```
/goal Implement PRD-020 per docs/prds/refill-pipeline/PRD-020-packing-complete-but-partial.md. Objective: let a packer skip an unfulfillable line and finish the task as "Complete but Partial". FE only (boonz-erp). No migration, no new RPC, no schema change. The backend already supports this; only the packing screen needs wiring.

STATE (verified live 2026-06-16, do not re-diagnose):
- skip_dispatch_line(p_dispatch_id uuid, p_reason text) sets skipped=true, include=false, skip_reason. Roles field_staff/warehouse/operator_admin/superadmin/manager. reason >= 10 chars. Refuses if picked_up, already skipped, or cancelled.
- unskip_dispatch_line(p_dispatch_id uuid, p_actor uuid default null) reverses while not picked up.
- confirm_machine_packed(p_machine_name text, p_dispatch_date date, p_packed_by uuid, p_reason text) counts a line UNRESOLVED only if include=true AND not cancelled AND not packed AND not skipped AND pack_outcome<>'not_filled' AND action in (Refill,Add New,Add). If any unresolved it returns status='blocked' + the list; else it writes dispatch_pack_confirmation with summary {total_included, packed, partial, not_filled, skipped}. reason >= 10 chars.

BUILD (src/app/field/packing/[machineId] and its row component):
1. Per-line Skip control on each Refill/Add New row that is not yet packed or picked_up. Opens a small reason picker (out of stock, expired, damaged, wrong product, other) plus free text; compose to a >= 10 char reason; call skip_dispatch_line(dispatch_id, reason); optimistic update then refetch.
2. A skipped row renders muted/struck with "Skipped: <reason>" inline and moves out of the outstanding-to-pack group. Show an Undo that calls unskip_dispatch_line; hide Undo once picked_up.
3. Progress math: resolved = packed + skipped + (pack_outcome='not_filled'), over included, non-cancelled, fillable lines. Header reads "resolved/total". Enable "Mark All Packed" only when resolved=total.
4. Completion: on click call confirm_machine_packed(machine, date, packed_by, reason). Render the returned summary: "Complete" when skipped=0 and not_filled=0, else "Complete but Partial - N skipped" listing the skipped product names + reasons. Banner is success or amber, never red/incomplete. Any machine roll-up card shows the same partial badge.
5. Skipped lines (include=false) are already excluded from pickup/dispatch; just make sure pickup view does not render them.

VERIFY:
- NOVO-1023 today: skip Pepsi Black (A03) with a reason -> progress shows 12/12 (11 packed, 1 skipped) -> Mark All Packed succeeds -> banner "Complete but Partial - 1 skipped (Pepsi Black: out of stock)".
- Undo on the skip restores it to outstanding and drops progress to 11/12 while not picked up.
- confirm_machine_packed never returns 'blocked' from the happy path because the button is gated on resolved=total.
- npx tsc --noEmit clean; npx next build.

RULES: FE only; no DB / RPC / migration; do NOT change skip_dispatch_line or confirm_machine_packed logic; no em dashes in UI copy; forward-only; own branch/commit. Show me the diff and the preview behaviour; STOP before deploying to main pending CS sign-off.
```
