# PRD-109 — Pre-Flight Refill Gate (perfect refill as a machine-checked property)

**Status:** DRAFT — top build priority per CS 2026-07-29 ("I really want a system that is flawless")
**Owner:** Dara (design) + Stax (advisory/FE wiring) + Cody (review)

## Problem

Every incident this week was a DISAGREEMENT between two sources that both claim truth, discovered downstream by a human: FE vs backend on "packed"; percentile vs volume on "hero"; machine-scoped vs global mapping on "what variants exist" (Extra Gum: 19 Spearmint in stock while stitch reported total stockout); pod_inventory vs WEIMI on "what's on the shelf"; view vs base table on shelf identity. The system has many single-purpose truths and no reconciliation, so every plan gambles on which seam it crosses, and CS is the de-facto validation layer. Vigilance does not scale — on 07-29 even the assistant's manual verification missed the Extra Gum ghost stockout because it trusted the stitch's own error message.

"Perfect refill" must stop being an outcome someone hopes for and become a property the system PROVES before commit.

## The contract

One read-only RPC: `preflight_refill_plan(p_plan_date date)` returning
`(verdict text 'PASS'|'FAIL'|'PASS_WITH_WARNINGS', violations jsonb[], warnings jsonb[], checked_at, invariant_versions jsonb)`.
Each violation names: invariant id, machine, shelf, product, expected vs found, and the fix path (RPC to call).

**Gating:** `stitch_pod_to_boonz(p_dry_run=false)` refuses when preflight returns FAIL (override only via explicit p_force + reason, audited). The 8pm advisory prints the verdict line. FE Commit shows it. The assistant commits only on PASS.

## Invariant set v1 (every one has bitten us; each carries its incident date)

- **INV-01 name-level WH coverage (07-29 Extra Gum):** every qty>0 warehouse-sourced line has pickable stock ≥ qty summed across ALL variants of the pod by product NAME — bypassing product_mapping scoping entirely. Machine-scoped mapping may pick the SKU; it may never hide sibling stock.
- **INV-02 mapping shadow detector (07-29):** planned pod has machine-scoped mapping AND global-only sibling variants WITH stock that the machine scope excludes → warning with unit counts.
- **INV-03 in-machine duplicate adds (07-29 Barebells/CCZ):** no ADD_NEW for a pod already on any shelf of the machine unless its existing facing is DOUBLE DOWN.
- **INV-04 orphaned swap legs (07-29 MC A15):** every REMOVE paired with an ADD_NEW whose fill is 0/not_filled → flag before driver departs, not after.
- **INV-05 suppressed M2W (07-28 rule):** zero M2W rows qty>0 in any non-rejected status; M2W is banned as auto-outcome.
- **INV-06 conservation:** superseded/excluded legs excluded from conservation counts (bug_conservation_counts_superseded_remove); per-machine unit balance holds.
- **INV-07 slot-guard parity:** every planned line's pod matches WEIMI physical slot or is a same-shelf swap pair.
- **INV-08 pack-progress parity (07-29):** v_dispatch_pack_progress and confirm_machine_packed agree for the plan date (post-PRD-107 this is structural; assert anyway — asserts are cheap, regressions aren't).
- **INV-09 guardrail products:** no Evian 1L swap-in; no venue_team product on a Boonz PO line or non-VOX warehouse line; no decommission-intent product added anywhere.
- **INV-10 empty-shelf outcome:** no shelf ends the plan at projected 0 stock with no ADD/REFILL and no explicit CS decision row (catches the "gum shelf stays empty" class even when stock is genuinely absent — forces a visible decision).
- **INV-11 stale binding / drift:** no planned line on a shelf where pod_inventory identity contradicts WEIMI beyond the known-archived set (surfaces the A14-class drift as a warning with the resync command).
- **INV-12 wh routing:** every line's from_warehouse resolvable and consistent with machine routing (VOX→MM/MCC, else CENTRAL); no blocked_no_wh row where INV-01 finds name-level stock.

## Growth rule (the compounding clause)

Every future refill incident MUST end with a new invariant (or a strengthened existing one) added via forward-only migration, version-stamped in `invariant_versions`. An incident that recurs without its invariant having existed is a process failure; an incident whose invariant existed and passed means the invariant is wrong — fix it. Post-mortems produce assertions, not memories.

## Placement in the flow

6am pre-pick → 8pm draft build → **preflight (auto, result into advisory email)** → CS reviews advisory → morning receipt/edits → **preflight re-run at FE Commit (blocking)** → stitch → push → pack (PRD-107 view) → driver.

## Acceptance

- Replay 07-29 as fixture: preflight FAILs citing INV-01 (Extra Gum, 19u found vs stockout claim), INV-03 (Barebells/CCZ), INV-04 (A15 orphan), with correct fix paths.
- Full-fleet run < 10s (advisory-compatible).
- stitch(false) refuses on FAIL; p_force path audited.
- Advisory email carries verdict; FE Commit displays it (Stax).
- pgTAP per invariant: one violating fixture + one passing fixture each.
- Cody review; registry + changelog; EXECUTION-LOG with verdicts.
