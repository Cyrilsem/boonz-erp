# PRD-063 — Fix main-track P1 shortlisting (rewrite v_machine_priority to shelf-aware urgency)

Status: Shipped 2026-06-28 (prod + main 31b9031). New main-P1 reproduces the locked list; T1-T7 pass; Cody ✅. Knobs in pick_urgency_params; rollback file held.
Owner: CS · Author: Cowork conductor · Date: 2026-06-28
Governance: Dara (design) → Cody (Article 16 canonical writer) → apply. No shadow.

## Problem

The 6am picker (`pick_machines_for_refill`) shortlists the main-track P1 set with
`WHERE p_tier='P1_RESTOCK' ORDER BY p_score DESC` — i.e. it reads `v_machine_priority`, which
is still the OLD machine-level logic (fill %, empty-shelf count, dead-slot %, under-25, machine
runway). That mis-shortlists. Proven live on today's main track (2026-06-28):

|            | OLD main P1 (live)                        | NEW model                                                                         |
| ---------- | ----------------------------------------- | --------------------------------------------------------------------------------- |
| top slot   | MC-2004 (83, empty+dead+intent)           | dropped — no seller running out                                                   |
| #2         | ALJLT-1015-0200 (60, empty+dead)          | dropped — cosmetic                                                                |
| missing    | —                                         | **ADDMIND-1007 added** — a top seller ~1 day from empty, not even on the OLD list |
| also added | —                                         | GRIT-1022 (overdue 26 days)                                                       |
| dropped    | NOVO-1023 (under25+dead)                  | cosmetic                                                                          |
| kept       | AMZ-1029, USH-1008, WPP, HUAWEI, AMZ-1038 | same (expiry/seller)                                                              |

OLD wastes its top two slots on empty/dead machines and misses the real stockout.

## Goal

Replace `v_machine_priority`'s tiering with the locked shelf-aware urgency model and
identity-based velocity, **in place** — no shadow, picker code untouched, cards + VOX labels
refresh from the same view. A machine is P1 only when a selling shelf will empty before the
upcoming refill, expired stock needs pulling, or it's overdue. Dead-stock stays OUT of the
picker (lives in ADD/SWAP). Supersedes PRD-058's view body.

## The model (locked with CS)

Per enabled shelf: daily velocity `dvel` (sales 30d ÷ facings), `dos = stock/dvel`, grade
A ≥ 0.5/day, B ≥ 0.2, C > 0, D = 0. Components 0–100:

- `s_runout` 0.50 — `gradeWeight(A1/B.6/C.25) × clamp((H−dos)/H)`, H = horizon (2d);
  machine = 0.75·worst-shelf + 0.25·breadth.
- `s_capacity` 0.15 — `1 − Σstock/Σcap` over A/B/C shelves only (D never counts).
- `s_expiry` 0.20 — `(2×expired + 1×expiring≤3d) / 6`, capped.
- `s_stale` 0.15 — 0 at ≤7d, ramp to 100 at 21.
  `urgency = Σ`. **Tier (overrides first):** P1 if hero (A-shelf dos < H AND days_since_visit > 1
  cooldown) OR stale (dsv > 14) OR expired ≥ 1 OR urgency ≥ 50; else P2 if expiring≤3d ≥ 3 OR
  urgency ≥ 25 OR any A/B dos < H; else SKIP. All weights/floors/thresholds tunable.

## Two layers (unchanged separation)

Tiering is UNCAPPED in the view (P1 = importance). The 8-cap stays a SELECTION limit inside the
picker, MAIN track only (`p_max_total`/`driver_capacity`); surplus P1 rolls to next day. VOX
is a parallel track — tiered + visible, serviced on its Wed/Fri cadence by the other team, not
against the main cap.

## Design (the one change set)

1. **`pick_urgency_params`** singleton (id=1 CHECK id=1; RLS SELECT true; writes
   operator_admin/superadmin/manager): horizon, A/B floors, grade + component weights, expiry
   norm + override mins, stale grace/full + override day, cooldown, p1/p2 thresholds,
   `driver_capacity`. Seed to the locked defaults.
2. **`v_shelf_sales_identity`** resolver: join shelf → sales velocity on `pod_product_id`
   (shelf carries it; sales resolve via `product_mapping`/`vox_product_mapping`), name-string
   only as last-resort fallback. Fixes Hunter ≡ "Hunter Ridge" reading as dead; keeps
   Pepsi Regular ≠ Black separate. Expose `resolved` + a coverage metric.
3. **Rewrite `v_machine_priority` in place**: consume `v_live_shelf_stock` +
   `v_shelf_sales_identity` for shelf velocity; compute the components, urgency, overrides;
   emit `p_tier` ∈ {P1_RESTOCK, P2_MAINTAIN, P3_OK} and `p_score = urgency`. **Keep every output
   column** the picker/cards consume; rebuild `reasons_arr` from the new triggers
   (hero/stale/expired/exp≤3d/seller<2d); add `urgency`/`soonest_a_dos`/grade counts as new
   columns. CROSS JOIN `pick_urgency_params`.
4. **Consumers untouched**: `pick_machines_for_refill` (main P1 = `p_tier='P1_RESTOCK'` ranked
   by `p_score`, cap-8, VOX branches all unchanged), `get_machine_health` cards, 8pm
   `build_draft_for_confirmed`.

## Acceptance tests (all pass; STOP on fail)

- T1 `v_machine_priority` returns full fleet < 800 ms; new main-track P1 reproduces the locked
  list (drops MC-2004/ALJLT/NOVO, adds ADDMIND/GRIT) on default params.
- T2 name-match coverage (matched ÷ enabled shelves) ≥ 95%; Hunter shelves resolve to their
  "Hunter Ridge" velocity; Pepsi Regular stays separate from Black.
- T3 picker parity of mechanics: main P1 = view P1 by `p_score`, cap-8 honored, VOX Wed/Fri
  gate + sibling expansion + `machines_to_visit` contract all unchanged.
- T4 cards (`get_machine_health`) show the new P1/P2 counts.
- T5 `engine_add_pod`/`engine_swap_pod` byte-identical; swaps_enabled false.
- T6 single-row param guard.
- T7 rollback migration restores the prior `v_machine_priority` body exactly.

## Rollback

One forward migration reverts `v_machine_priority` to its current body; `pick_urgency_params`
is data. No picker/FE change to undo.

## Dependency / risk

Without a shadow, the only accuracy risk is shelf velocity — handled by building
`v_shelf_sales_identity` INTO this same change and gating apply on ≥95% coverage (T2). After
apply, the 6am picker shortlists the new main P1 that morning; the 8pm draft builds on it.

## Also

Update boonz-master-3 (engine table: picker reads urgency-based `v_machine_priority`; routing
"why is X P1/P2"; Step-0 description; `pick_urgency_params` knobs; dead-stock now ADD/SWAP).

## Out of scope

Dead-stock phase-out (ADD/SWAP). Revenue/margin weighting. FE picker code.
