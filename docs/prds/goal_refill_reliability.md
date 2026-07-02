# /goal — Refill Pipeline Reliability (Claude Code edition)

Paste this to Claude Code to start. **All paths below are inside the `boonz-erp/` repo (your readable sandbox).**

---

**GOAL:** Execute the workstreams in `docs/prds/PRD_refill_reliability_2026-06-03.md` to make the Boonz refill pipeline reliable end-to-end (submission, dispatch, inventory accuracy, recommendation fidelity).

**Read first (all in-repo, readable):**

- `docs/prds/PRD_refill_reliability_2026-06-03.md` (the spec, incl. WS3 Simran corrections)
- `docs/prds/refill_postmortem_2026-06-03.md` (root-cause analysis)
- `docs/architecture/01_constitution.html`, `docs/architecture/RPC_REGISTRY.md`, `docs/architecture/MIGRATIONS_REGISTRY.md`

**Environment note:** There is **no `boonz-master-3` conductor skill in this project** — do not try to load it. Governance is the Backend Constitution enforced via the skills you DO have: **`cody`** (constitutional review of every SECURITY DEFINER fn / protected-entity DDL), **`dara`** (schema design), **`stax`** (FE). Those cover every required gate; the conductor is not needed here.

**Hard rules (non-negotiable):**

1. Run every `CREATE OR REPLACE` SECURITY DEFINER fn and every DDL on an Appendix-A protected entity through the `cody` skill; record the verdict. Use `dara` for schema, `stax` for FE.
2. NEVER raw `UPDATE/INSERT/DELETE` on `pod_refill_plan`, `refill_plan_output`, `refill_dispatching`, or any protected entity — go through a canonical RPC; build the RPC first if none exists.
3. NEVER move/reduce real inventory counts without printing the per-row diff and getting CS sign-off. `warehouse_inventory.status` is manager-only (propose-then-confirm). Archive (status→Inactive), never DELETE.
4. **Apply nothing to prod without CS sign-off** — author + Cody-review migrations as staged files under `supabase/migrations/`, and STOP for CS at each apply and at each WS3 inventory diff. (Supabase project: `eizcexopcuoycuosittm`.)
5. Multi-variant splits = even (±1), FEFO oldest expiry first. No em-dashes in client-facing copy.

**Order of work:**

1. **WS1b** — stitch resolve REMOVE/M2W to a concrete boonz variant (or skip qty-0 REMOVE) so swaps stitch+dispatch in one pass. (WS1a confirm-on-error gate already shipped to prod 2026-06-03 as `phaseF_stitch_gate_confirm_on_write_ok`.)
2. **WS2** — `push_plan_to_dispatch` edit-aware (stop clobbering manual dispatch swaps) + new `skip_dispatch_line` canonical writer so an unfulfillable line never hard-blocks submission.
3. **WS3** — reconcile WH↔pod inventory for 2026-06-03 to 0 balance: drain delivered packed lines, release un-picked, then apply Simran's per-item corrections (PRD §3.WS3) one diff at a time with CS sign-off. Log today's manual/missing refills.
4. **WS6** — repin Red Bull / Vitamin Well variants; suppress packing rows for variants with literally 0 stock anywhere (variant-row suppression, NOT the WH-availability gate, which is an explicit non-goal).
5. **WS4** — wire `driver_feedback` into `engine_add_pod` as a prioritized demand signal with decay.
6. **WS5** — recommendation translator: free text → typed `recommendation_intents` → `apply_mix_weight_recommendation` updating per-machine `product_mapping.mix_weight` (boonz-level) or swap/decommission (pod-level). Human-confirm before any write.
7. **WS7** — FE (`stax`): Stock + last-7d columns on the pending Refill Planning view; availability UX ("reserved to {machines}").

**Already staged (do not redo):** if `supabase/migrations/20260603120000_refillv2_ws1b_skip_qty0_physical_remove.sql` exists, it's the WS1b qty-0-skip half, Cody-approved — verify + hand to CS for apply, then proceed to the variant-resolution half.

**Do NOT** implement WH-availability gating of refills (explicit non-goal until the ledger is stable).
**Definition of done:** a refill can be built, edited (incl. swaps), submitted, dispatched, packed, picked up, and received with the ledger netting to zero — and driver/CS recommendations measurably shape the next plan.
