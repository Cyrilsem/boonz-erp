# Claude Code /goal Command - PRD-049 (condensed)

Paste into Claude Code in `boonz-erp`. Supabase eizcexopcuoycuosittm. FE-only stabilization. Phased; QA each phase on a phone, then promote. No em dashes. No backend changes unless a real RPC bug is found (then Cody).

```
/goal Implement PRD-049 (docs/prds/PRD-049-packing-returns-fe-stabilization.md); read it first. Fix six FE defects in the live packing screen + returns approval. The backend is sound (verified 2026-06-22): edit_dispatch_qty persists qty; skip_dispatch_line records the skip; confirm_machine_packed(p_final) already counts not_filled AND skipped as resolved (only untouched lines block Finish); receive_dispatch_line already accepts a per-expiry p_batch_breakdown. These are UI bugs: lost edits, mis-gated Finish, missing per-variant/per-expiry controls.

RULES
- FE only. Use existing RPCs (S1: never .from(table) writes). If you think a real RPC bug exists, stop and route to Cody; do not edit a DEFINER body casually.
- Read the live FE first: src/app/(field)/field/packing/[machineId]/page.tsx (3748 lines) and src/components/inventory/PendingRemoveApprovalsPanel.tsx. Base fixes on what is there.
- Deploy to a Vercel PREVIEW, QA on a phone against the reported symptom, then promote. No em dashes in copy. Per phase: show the diff + the QA result, then STOP for CS.

STATE (verified live 2026-06-22, do not re-diagnose):
- Today's refill: HUAWEI 96 refill lines (60 skipped), ALJLT-0200 50 refill (31 skipped); not_filled=0 fleet-wide. Heavy fragmentation + skipping.
- Pack-gate: confirm_machine_packed(p_final) blocks only when an included Refill/Add New line is neither packed nor skipped nor pack_outcome='not_filled'. not_filled and skipped ARE resolved. So issue 3 is the FE button-enable state, not the gate.
- packed_qty is FE local state overwritten to recommended_qty on merge (page ~L1220) = issue 1.
- skip_dispatch_line needs reason >= 10 chars; the skip dialog (skipCategory+skipNote) can produce a short reason that throws = issue 2.
- PRD-044/045 packing FE shipped on main (37ce14d); PRD-047 B3 swap deploy was Vercel rate-limited (4e95dcb) = confirm it is live before treating issue 4 as all-new.

PHASE A (issues 1,2,3 - highest impact, every refill):
1. Persist edited pick qty: drive pack_dispatch_line picks from the edited value; do not clobber packed_qty back to recommended_qty on refetch.
2. Skip: enforce/auto-pad the composed skip reason to >=10 chars; surface skip_dispatch_line errors instead of swallowing them so users stop falling back to not_filled.
3. Finish gate: make Save/Finish enablement mirror the backend exactly - enabled when every included line is packed OR skipped OR not_filled; a resolved line must never disable it. Keep PRD-044 Save-and-come-back available throughout.
QA: re-pack HUAWEI today - edit a qty (persists), skip with a short reason (processes), mark last line not_filled (Finish stays enabled for the rest).

PHASE B (issue 4 - swaps): per-variant qty edit + per-variant skip/set-0 for multi-flavor swaps; fix variantQtys reset-to-0-after-confirm; a flavor set to 0 must not move to pod inventory. Confirm PRD-047 one-tap swap is actually deployed.

PHASE C (issue 5 - transfer with edit): trace edit-qty -> pick-destination -> apply for M2M transfer lines; fix the wiring so an edited transfer completes (both legs correct). Backend writers exist (mark_internal_transfer / swap_between_machines / set_dispatch_source).

PHASE D (issue 6 - returns expiry-split): add a Split-by-expiry control to PendingRemoveApprovalsPanel for a single product across multiple expiries; build a per-expiry p_batch_breakdown and call the existing receive path so each expiry batch is credited to its own warehouse_inventory row. Works inside the existing approval model.

CONFIRM per phase, pass/fail vs the reported symptom. Start with Phase A on a preview URL; show me the diff + phone QA before promoting.
```

PRD: `boonz-erp/docs/prds/PRD-049-packing-returns-fe-stabilization.md`.
