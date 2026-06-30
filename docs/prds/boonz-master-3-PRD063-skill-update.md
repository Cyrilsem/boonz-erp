# boonz-master-3 SKILL.md — replacement sections for PRD-063 (picker urgency)

Paste these into the boonz-master-3 skill (Settings → Capabilities). Each block says what to
REPLACE. The picker now reads a shelf-aware **urgency** model, not the old machine-level signals.

---

## 1) Engine-versions table — REPLACE the two picker rows

REPLACE the `Cron — Picker` row with:

| Cron — Picker | `pick_machines_for_refill` | **v11** | 6am Dubai (cron 14, `0 2 * * *`) for `CURRENT_DATE + 1`. Reads `v_machine_priority` (now the PRD-063 **urgency** model). |

REPLACE the `1 — Picker` row with:

| 1 — Picker | `pick_machines_for_refill` | **v11** | Tiers come from `v_machine_priority` = shelf-aware **urgency** (PRD-063, applied 2026-06-28). NOT the old fill%/empty-shelf/dead-slot logic. Main P1 = `p_tier='P1_RESTOCK'` ranked by `p_score` (=urgency), capped at `pick_urgency_params.driver_capacity` (8). VOX = parallel Wed/Fri track. Venue-sibling expansion kept. |

---

## 2) NEW section — insert after the engine-versions table

### The picker urgency model (PRD-063, live 2026-06-28)

`v_machine_priority` is the ONE place P1/P2 is decided (picker + Stock-Snapshot cards both read
it). It is now **shelf-aware urgency**, driven by the tunable `pick_urgency_params` (one row,
id=1) + the `v_shelf_sales_identity` velocity resolver. PRD-058's dead-stock dial is superseded.

Per enabled shelf: velocity = sales 30d via identity resolver (matches on `pod_product_id`, so
"Hunter" ≡ "Hunter Ridge"); days-of-supply `dos = stock/velocity`; grade A ≥ 0.5/day, B ≥ 0.2,
C > 0, D (dead) = 0. `urgency` (0–100) = 0.50·runout + 0.15·capacity(A/B/C only) + 0.20·expiry

- 0.15·stale.

Tier (overrides first):

- **P1** if: a **hero** A-shelf is < 2 days from empty (and the machine wasn't visited in the
  last 1 day — cooldown) · OR **stale** > 14 days since visit · OR **expired ≥ 1 unit** to pull
  · OR urgency ≥ 50.
- **P2** if: expiring-≤3-day units ≥ 3 · OR any A/B shelf < 2 days · OR urgency ≥ 25.
- **SKIP** otherwise.

Two layers: tiering is UNCAPPED (P1 = importance). The **8 cap is a selection limit** in the
picker, MAIN track only; surplus P1 rolls to the next day. **VOX is a separate track**
(serviced Wed/Fri by the other team; we do it ~1–2×/week) and does NOT consume the main 8.

**Dead/empty shelves are NOT a picker trigger.** An empty shelf only matters if it SELLS (a
hero hitting 0 → runout). Empty/dead cosmetics belong to ADD/SWAP, not the pick.

Tune live with a one-row UPDATE, no migration:
`UPDATE pick_urgency_params SET <knob>=<value> WHERE id=1;` (horizon, A/B floors, the 4
component weights, expiry/stale/cooldown params, p1/p2 thresholds, `driver_capacity`).

---

## 3) Routing table — REPLACE the "why is X" rows and ADD a P1/P2 row

REPLACE `why is this shelf 0 / tagged for swap` answer with:

| why is this machine P1 / P2 / SKIP | read `v_machine_priority.p_tier` + `reasons_arr` (hero / stale / expired / exp≤3d / seller<2d). P1 = a seller about to run out, expired stock to pull, or >2 weeks overdue. SKIP = nothing selling is low, no expiry, recently visited. Dead/empty-but-not-selling does NOT make P1. |

ADD:

| the pick looks like the OLD logic (empty/dead/under25 reasons, old scores) | the stored `machines_to_visit` rows are STALE — written by a cron that ran before PRD-063 landed. The live view is correct. Refresh with `pick_machines_for_refill('<plan_date>')`; future 6am crons use the new model automatically. |
| re-pick a date / fix today's route | `pick_machines_for_refill('<plan_date>')` — supersedes the prior pick and clears `confirmed_at`. Safe on a non-dispatched date only; never on a stitched/dispatched plan. |
| change how many machines per day / retune priority | one-row UPDATE on `pick_urgency_params` (e.g. `driver_capacity`, weights, thresholds). No migration; cards + picker pick it up immediately. |

---

## 4) Step-0 / "what's the plan" note — ADD this line

When inspecting a plan_date, check `machines_to_visit.picked_at` vs when PRD-063 went live
(2026-06-28). If the pick predates it OR its `picked_reasons` contain old tokens
(`empty_one`, `dead_slots`, `shelves_under25`, `high_velocity`), the pick is stale — re-run
`pick_machines_for_refill` for that date before trusting it.
