# /goal — PRD-029 Dispatch Line State Integrity (<2500 chars)

Paste into Claude Code in the boonz-erp repo.

---

/goal Implement PRD-029 per docs/prds/PRD-029-dispatch-line-state-integrity.md. Objective: skipped / cancelled / excluded dispatch lines become inert everywhere: cannot be packed, cannot be returned, never auto-finalized, never rendered in the driver app.

STATE (verified live 2026-06-12, do not re-diagnose): two same-day incidents. (A) OMDBB: WH manager packed 2 lines that were skipped with reason "CS: cancel OMDBB A07 Plaay swap"; packing FE shows skipped lines as packable. (B) VOXMM 13:31: driver tapped Dispatch Complete and the app's completion flow fired return_dispatch_line on all 5 skipped lines of the cancelled A03 swap ("by: system" in audit), crediting 11 phantom Tamreem units to WH_MM/WH_CENTRAL. Both recovered manually same day (apply_inventory_correction x4 + flag corrections). Verified: neither pack_dispatch_line nor return_dispatch_line checks skipped/cancelled/include.

RULES: Backend Constitution. pack_dispatch_line and return_dispatch_line are canonical writers: Cody review mandatory before apply. Forward-only migration phaseF_dispatch_state_guards (both functions, capture rollback functiondefs). No raw writes to refill_dispatching. Registries + CHANGELOG per change. No em dashes in copy.

BUILD ORDER:

1. Backend guards: pack_dispatch_line refuses skipped=true OR cancelled=true OR include=false with an error naming the flag + skip_reason. return_dispatch_line same three-flag refusal PLUS reject system-actor returns of lines never packed and never picked up (nothing physical to return). Confirm EOD sweep (eod_auto_release_unpicked) and release_stale_unpacked_dispatches do not route through return_dispatch_line. Cody -> apply -> battery items 1-4 from PRD §4.
2. Driver app: (a) do not render skipped/cancelled/include=false lines, exclude them from shelf totals; (b) Dispatch Complete finalizes ONLY lines the driver explicitly actioned, never auto-returns un-actioned lines (EOD sweep is the safety net); (c) returns require an explicit per-line tap + confirm dialog (qty + destination WH).
3. Packing FE: hide or hard-disable skipped/cancelled/excluded lines (guard from step 1 is the backstop).
4. Battery items 5-6: simulated visit with actioned + skipped + untouched lines; replay of incident B inputs produces zero WH writes.

DONE WHEN: battery 1-6 green, Cody sign-off recorded, registries updated, FE deployed to Vercel, each step committed separately and pushed.

Start with step 1. Show me both guarded function drafts and Cody's verdict before applying.
