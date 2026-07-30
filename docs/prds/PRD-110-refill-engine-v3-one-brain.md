# PRD-110 — Refill Engine v3 "One Brain"

**Status:** Draft for CS approval · **Author:** compiled with CS, 2026-07-30, from the 07-30 post-mortem, the v2 requirements gap sheet (BOONZ-V2-BOOTSTRAP/06), and the replenishment planner assessment.
**Companion:** PRD-110-goal-command.md (the one-shot execution loop).
**Repo decision:** SAME repo, SAME live Supabase (see §6). boonz-v2 inherits the result; it is not the build site.

---

## 1. Problem

A basic 8-machine refill cost CS 2 hours on 2026-07-30. Root causes (post-mortem): truth scattered across 4 stock reads and 2 scoring brains; ~93 shelves invisible to the engine (RC-06); availability faked via sentinels and warehouse pinning; edits adversarial to the engine; correctness dependent on ~30 tribal rules instead of constraints. Separately, the planner assessment found the engine optimizes availability, not revenue: censored demand signal, no variance/service levels, no visit economics, no demand shaping, no expiry ceiling, no space economics, no scoreboard.

The engine's core math (order-up-to, explainable reasoning JSON, stitch v30) is sound and is retained.

## 2. Goals (measurable, in priority order)

| G   | Goal                                     | Metric                                                            | Target                                     |
| --- | ---------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------ |
| G1  | One truth                                | # of distinct sources any consumer reads for shelf state          | 1 view, FE scorer retired                  |
| G2  | No invisible shelf                       | shelves with live stock but no plannable row                      | 0, enforced by constraint                  |
| G3  | Empty never skipped                      | enabled shelves at 0 stock without a plan line or logged decision | 0                                          |
| G4  | Uncensored demand                        | velocity computed on in-stock time                                | 100% of shelves                            |
| G5  | Revenue lift                             | fleet revenue/machine/day vs 4-week pre-v3 baseline               | +10% within 8 weeks of cutover             |
| G6  | OSA on A-shelves (top-velocity quartile) | in-stock rate                                                     | ≥ 97%                                      |
| G7  | Waste                                    | expired units ÷ units sold                                        | < 2%, trending down                        |
| G8  | CS edit speed                            | dictated instruction → confirmed plan diff                        | ≤ 2 min, zero data archaeology             |
| G9  | Blocked demand captured                  | blocked/clamped units logged and visible to procurement           | 100%                                       |
| G10 | Trustworthy autonomy                     | machine-clusters promoted to auto-with-veto                       | ≥ 50% of fleet within 12 weeks, KPI-earned |

Non-goals: rebuilding ingestion, driver app, or settlements; changing the pod/SKU two-level model; boonz-v2 migration (separate track).

## 3. The four-layer brain (rule-based × reasoning blend)

```
L0 DETERMINISTIC CORE — owns every number. Auditable, versioned, golden-tested.
   velocity* = sales ÷ in-stock hours (WEIMI)            [kills censoring]
   target S  = μ(visit_interval+lead) + z·σ              [machine_service_policy.z — finally read]
   ceiling   = min(S, days_to_expiry × safety, capacity) [perishability]
   demand×   = macro KPI (industry×machine×week, CS's existing table) × event calendar × DOW profile
   floor     = unconditional: enabled shelf + stock 0 ⇒ line exists (cold-start priors by category archetype)
L1 OPTIMIZATION PASS — allocation under constraints.
   WH allocation by priority (value-at-risk order, not first-come);
   swap/substitution ladder: variant → Pearson substitute → margin-up substitute →
   other WH → M2M from overstocked sibling → blocked_demand log (never silent qty-0);
   facing rightsizing + rotation heartbeat (rotation_proposals scheduled, fit-scored);
   route/day plan by value-at-risk vs visit cost, capacity-aware.
L2 REASONING LAYER (LLM) — owns language and exceptions, never quantities.
   CS dictation → compiled plan-diff table (Gate style preserved);
   anomaly triage (drift, sensor lies, conservation flags) with proposed fixes;
   explanation of any line on demand ("why 7?" answered from reasoning JSON).
L3 LEARNING LOOP — weekly.
   WMAPE per machine-class → parameter tuning proposals (z, cover, uplift factors);
   golden-example regression must stay green; waste/OSA trends → assortment proposals.
```

## 4. Workstreams and acceptance criteria

### WS-A Truth layer (foundation — blocks everything else)

- A1 `shelf_state` canonical view: shelf → machine, product, stock, capacity, sourcing, in-stock-hours velocity, signal, expiry summary. One row per enabled shelf, **guaranteed** (auto-provision trigger on shelf_configurations insert; phantom shelves excluded by definition).
- A2 `sourcing` first-class enum on the shelf/product edge: `boonz_wh | venue_consignment | partner`. Venue = unconstrained by definition. **Sentinel 999 rows retired** after migration.
- A3 Warehouse resolution at plan time by product location (or auto-transfer line generated) — kills machine-pinning strandings (Pepsi Black case).
- A4 FE machine page reads shelf_state. Second scorer deleted.
- ✔ Accept: G1, G2 pass; the 07-30 "three empty machines" fixture produces full plans.

### WS-B Guarantee layer

- B1 Empty-shelf unconditional rule (G3) with cold-start priors.
- B2 Coverage + conservation as blocking constraints at commit (preflight invariants promoted from advisory; INV-06 REMOVE false-positive fixed).
- B3 FEFO binding inside the approve transaction.
- ✔ Accept: OMDBB Coca-Cola Zero fixture refills; commit is impossible with an unexplained uncovered shelf.

### WS-C Demand & quantity brain (L0)

- C1 In-stock-hours velocity (G4). C2 Service-level targets reading machine_service_policy. C3 Expiry ceiling. C4 Demand multipliers: CS macro KPI table plugged + events (context-intelligence) + DOW. C5 Stockout-decay guard ported from procurement brain.
- ✔ Accept: WMAPE baseline recorded; Spider-Man fixture sizes above baseline Tuesday; short-dated fixture caps below cover target.

### WS-D Optimization pass (L1)

- D1 Substitution ladder (never silent qty-0). D2 Swap engine re-wired (tag LIKE fix) + margin-weighted. D3 Rotation heartbeat: weekly job → proposals → CS gate → M2M lines at SKU level (pod-mismatch fixed). D4 Facing rightsizing proposals. D5 Value-at-risk picker + day capacity model (driver hours, clusters); machine_service_policy cadence.
- ✔ Accept: Krambals&Zigi→Zigi fixture executes as SKU-level transfer; Tamreem-facing fixture generates a rightsize proposal.

### WS-E Editing & gates (CS style)

- E1 Gate 0: **first wave = manual activation ONLY** — engines run only on CS-selected machines, no auto-fallback (CS decision 2026-07-30). Auto-fallback becomes available per-cluster only at autonomy A2+. Pick-learning module (see WS-H4) mines CS's adds/drops vs cron picks to converge the picker on CS's judgment.
- E2 Edits as events: human lines carry locks; engines re-run around them, never wipe.
- E3 One pipeline: dictated instructions compile into the same plan (no parallel conductor path); single approve vocabulary; one-verb swap (same or cross machine).
- ✔ Accept: replay of the 07-30 session's 9 CS edits, then an engine re-run, preserves all 9.

### WS-F Feedback & measurement

- F1 `blocked_demand` ledger written by L0/L1, consumed by weekly-procurement, threshold-triggered draft POs (G9).
- F2 Scoreboard: OSA, stockout rate, waste%, WMAPE, plan adherence, revenue/machine/day, blocked-demand aging — per machine and fleet, daily.
- F3 Expiry trust fix (KPI-vs-drawer issue) then automated Remove/write-off lines.
- ✔ Accept: G5–G7 measurable from day one of shadow mode.

## 5. Golden examples (the "what right looks like" harness — build FIRST)

Fixtures from real history; each = frozen input state + expected plan. Regression must stay green through every change. Seed set:

1. 07-30 VOX event night (full replay: picks, edits, PO, expected 220u outcome)
2. OMDBB Coca-Cola Zero — cold start / censored velocity
3. MPMCC-1058 — machine with 1 lifecycle row must still plan 16 shelves
4. Krambals & Zigi → Zigi cross-pod M2M at SKU level
5. Fade Fit dual-sourcing — venue supply, no PO, never blocked
6. Pepsi Black — stock in CENTRAL, machine draws MCC → auto-transfer or reroute
7. Spider-Man uplift vs normal Tuesday (same machine, two dates)
8. Short-dated batch — expiry ceiling beats cover target
9. NOOK 07-20 — manual-refill recovery path
10. Superseded REMOVE — conservation must not false-stop
11. AMZ drop mid-plan — freed stock re-allocated, not stranded
12. Evian 1L — guardrail products never swap in
13. Empty shelf + zero WH + venue alternative → substitution ladder outcome
14. Sensor lie (WEIMI stock > capacity) → anomaly triage not plan corruption
15. New machine day-1 — priors produce a sane plan with zero history
    (+ grow with every future incident: an incident is closed only when its fixture exists)

## 6. Repo & delivery model

**Same repo + live Supabase.** Rationale: the engine is inseparable from live ingestion/dispatch/driver/FE; a parallel-project rebuild starves live ops and duplicates integration risk. Method: additive schema (Dara design → Cody review, per constitution), versioned RPCs (`*_v3`), feature flags per machine-cluster, and **shadow mode** — v3 runs nightly beside the live engine, plans diffed, scoreboard compared; cutover per cluster only when v3 wins ≥ 2 consecutive weeks. boonz-v2 ports the proven schema + engine, never hosts the experiment. Rollback = flag flip.

## 7. Autonomy ladder (the "eventually independent" path)

A0 shadow (no writes) → A1 advisory (draft + CS commit, today's model) → A2 auto-with-veto (plan auto-commits at deadline unless CS vetoes; Gate 0 still human) → A3 autonomous (exception-only surfacing). Promotion per machine-cluster, earned by: OSA ≥ target, WMAPE ≤ threshold, waste ≤ target, 2 weeks zero manual corrections. Demotion automatic on breach.

## 8. Sequencing

Phase 0 (this week, live system, no refactor): swap-tag LIKE fix · slot_lifecycle backfill · Gate-0 confirm flip · Fade Fit sentinels (bridge) · crude blocked_demand insert from existing JSON.
Phase 1: WS-A + golden harness. Phase 2: WS-B + WS-C. Phase 3: WS-D + WS-E. Phase 4: WS-F + shadow mode. Phase 5: cluster-by-cluster cutover + autonomy ladder.
Each phase ends at a Cody-reviewed gate with the regression set green. The loop does not stop inside a phase (see goal command).

## 9. Risks

- Sentinel retirement touches settlement/COGS surfaces → Cody review + SOA regression fixture required.
- In-stock-hours velocity re-ranks the whole assortment at once → introduce in shadow, compare before cutover.
- Edits-as-events changes FE contract → Stax ticket batch, PRD-107 pattern.
- Expiry work is blocked by the open trust issue — sequence F3 before any auto write-off.

## 10. Addendum (2026-07-30b, CS) — feedback, self-learning, spot procurement

### WS-G Human feedback loop (driver + client + CS)

- G1 Unified `feedback_ledger`: source (driver/client/cs), machine, shelf, product, free text, structured kind. Driver entry = 2 taps in the app (wraps existing `driver_propose_adjustment`); client asks logged by whoever hears them; CS dictations auto-logged.
- G2 Auto-proposal generator: recurring or explicit feedback compiles to a **gated** change — mapping fix, min-facing pin ("always Coke Zero"), do-not-reduce pin ("keep Oreo depth"), split reweight. Wraps existing `propose_recommendation_intent`. Nothing self-applies below autonomy A2; every applied proposal cites its feedback rows.
- G3 Engine consumption: pins become L0 constraints (min facing, protected depth), read every run.
- ✔ Accept: "driver says don't reduce Oreo" fixture → logged → proposal → CS approve → next plan respects depth, provenance visible.

### WS-H Self-learning from edit history

- H1 Mining source already exists: `pod_refill_plan_audit` (before/after/reason on every manual change), reasoning.manual_edit JSON, dispatch outcomes, driver_feedback. Months of labeled training data accumulating since Phase F.
- H2 Weekly miner (L3): cluster recurring overrides (e.g. CS repeatedly trims product X on machine Y ≈ effective-fill preference; repeated same-shelf swaps ≈ assortment signal) → parameter/policy proposals with evidence, into the same gated proposal queue as WS-G.
- H3 Anti-goals: never learn from a violated-protocol edit (filter by reason codes); never silently change L0 parameters; every learned change is reversible and cited.
- H4 Pick-learning module (CS decision 2026-07-30): mine machines_to_visit history — cron pick vs CS cs_added/cs_dropped deltas — to learn CS's selection judgment (features: fill, runway, venue events, days-since-visit, cluster). Output: weekly picker-weight proposals + a live "CS would likely add/drop" hint on Gate 0. Success = delta rate between cron pick and CS's final selection trends toward zero.
- ✔ Accept: replay of 4 weeks of audit history produces ≥5 sensible proposals CS agrees with (measured by acceptance rate ≥60%).

### WS-I Same-day / spot procurement (the "no-wh forces a skip" fix)

- I1 Problem: on-the-spot purchases (driver or WHM buys missing product en route) have no capture path; pack skips the line because warehouse stock is zero. Organs exist: `po_additions`, `receive_purchase_order_addition`, walk-in driver_tasks.
- I2 Build: **atomic spot-buy** — one action (app button, WHM portal + driver app): product, qty, price, receipt photo → creates PO (or addition to today's open walk-in PO) + receives it into the correct WH + binds the waiting dispatch line, in ONE transaction. Blocked line flips to packable immediately.
- I3 Plan-side: L1 ladder emits "spot-buy candidate" as an explicit fallback step (before giving up), pre-authorized per product class + price cap set by CS; lands on the route as a shopping stop.
- I4 Ledger tie-in: every spot buy back-writes to blocked_demand (root cause) so procurement sees chronic gaps vs one-offs.
- I5 (CS decision 2026-07-30) Spot buy AUTO-CREATES the PO (who/how configurable later); on receive, inventory reflects immediately and **the refill plan is live and refreshable**: open plan/dispatch lines re-evaluate bindings on every inventory event — a skip caused by no-WH-stock flips to packable the moment the spot PO is received, without re-running the plan.
- ✔ Accept: McVities 07-30 fixture — blocked line + spot buy → packable same run, PO trail complete, no manual SQL.

### Additional goals

| G11 | Feedback → applied change cycle time | ≤ 1 week, provenance on every applied pin |
| G12 | Learned-proposal acceptance rate | ≥ 60% (else the miner is noise — retune) |
| G13 | Spot-buy capture | 100% of on-the-spot purchases entered via the atomic path; zero skip-due-to-no-wh for purchasable items |

### Additional golden fixtures

16. Driver "don't reduce Oreo" → pin lifecycle end-to-end.
17. Client "always Coke Zero" → min-facing pin enforced across 4 consecutive plans.
18. Spot-buy unblock (McVities replay): blocked → bought → bound → packed.

### WS-J Operating models + machine-level inventory redesign (CS, 2026-07-30)

**J1 Three operating models, first-class.** New `operating_model` on machines, driving reconciliation and planning rules — no more inference from venue_group + sentinels:

| Model             | Example      | Stock rule                                                                   | Reconciliation rule                                                                                       |
| ----------------- | ------------ | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `fully_managed`   | offices, AMZ | All products Boonz-sourced                                                   | Any stock rise without a Boonz event = anomaly, flagged                                                   |
| `co_managed`      | VOX          | Per-product sourcing edge (boonz / venue), **editable in FE, fully audited** | Rise on venue-sourced product = legitimate venue_fill event, auto-logged; rise on Boonz product = anomaly |
| `partner_managed` | LVLUP        | Zero Boonz inventory records                                                 | Telemetry + revenue reporting only; engine plans nothing                                                  |

Sourcing edits are one-click in FE (product × machine grid), constraint-validated (a partner_managed machine cannot carry a boonz edge), and versioned — "religiously tracked" means the audit trail is automatic, not procedural. Sentinel 999 rows retire fully: venue/partner products simply have no Boonz stock records, and the planner treats venue-sourced as unconstrained by definition.

**J2 Machine-level inventory: exact count + probabilistic composition with ground-truth collapse.**
(Revised same day after CS correction: machines are sensor-based grab-any-unit, NOT spiral — the removed unit's identity is fundamentally unobservable; FIFO was a simplifying fiction and is rejected. A "Chocolate Bar" shelf may hold 30 units across many SKUs with unknown mix.)

Observable facts: shelf count per snapshot (WEIMI) · vend timestamps (pod level) · driver-loaded SKUs+expiry (pack lines) · driver-removed SKUs (returns/write-offs) · the driver's eyes at every visit. Unobservable: WHICH unit left between visits. The design stores facts as facts and estimates as estimates:

1. **Count = telemetry, alone, exact.** The engine's refill QUANTITIES consume only this — insulated from composition uncertainty by design.
2. **Composition = estimate + confidence score, never presented as fact.** Per shelf: SKU/batch shares, seeded by load events, decremented **proportionally across SELLABLE candidates** on each count drop. FE always shows estimated vs last-verified (date + by whom).
3. **⛔ Expiry iron rule: an expired/near-expiry unit is NEVER consumed by assumption.** It exits only via explicit human event — write_off, return, or confirmed "expired-unit-sold" correction (which is logged as a food-safety incident KPI). Conservative bias is deliberate: worst case = a one-tap driver clear; the current system's bias silently un-flags expired stock.
4. **Ground-truth collapse at every driver touch — the audit IS the refill visit.** Driver app shows expected composition per shelf; tap-confirm or quick-fix; prompts appear ONLY on shelves flagged by uncertainty × value-at-risk (target ≤3 shelves/visit, ≤10s each). Upgrade path: one shelf photo at visit end → L2 vision identifies SKUs/facings → auto-collapse, human fallback. No separate audit tool, no audit schedule.
5. **Confidence gates automation.** Staleness + unexplained deltas decay confidence; low confidence raises audit priority and BLOCKS auto-actions (auto write-off lines require confidence ≥ threshold; below it, a verify task is generated instead). The system explicitly knows what it doesn't know.
6. **Observed mix replaces static split_pct over time:** pod sales attributed by confirmed compositions → dynamic SKU mix per shelf feeding procurement splits and COGS, superseding hand-maintained split_pct (drift source today).
7. **Everything is an immutable event** (load, venue_fill, return, write_off, spot_buy_receive, driver confirm/correction, derived decrement). No in-place SET adjustments anywhere; corrections are events with provenance. Warehouse side: same ledger pattern (stock born by PO receive/approved return, consumed by pack, corrected by count events).
8. **Anomaly rules per operating model** (J1): count rise without event = venue_fill (co-managed, venue-sourced) or flag (fully managed / Boonz product).

Migration: composition estimator built in shadow from existing pack lines + audit log + WEIMI history; diffed against pod_inventory 2 weeks; cutover; pod_inventory frozen read-only.

- ✔ Accept: fixture 19 (co-managed venue fill reconciles; Boonz-product rise flags) · fixture 20 (expired unit survives count drops until human event; auto write-off line only above confidence threshold) · fixture 21 (driver confirm collapses estimate without overwriting history) · fixture 22 (30-SKU Chocolate Bar shelf: composition confidence decays between visits, audit prompt fires, collapse restores) · fixture 23 (expired-unit-sold correction logs the incident KPI).

### Journey acceptance (the "subtle process" bar)

Planner: advisory → commit in ≤ 10 min on a normal day, zero SQL. WHM: zero surprises at pack; spot-buy ≤ 30 s. Driver: feedback ≤ 2 taps; mistake recovery has an undo window (no NOOK-class freezes). Client: a recorded ask never needs repeating. Procurement: blocked demand visible with aging, never re-discovered.

## 11. Decisions — CLOSED by CS 2026-07-30

1. Gate 0: **NO auto-fallback in first wave** — engines activate only on CS-selected machines until logic proves comprehensive; pick-learning module (WS-H4) added. Auto-fallback earns its way in at A2+.
2. Autonomy thresholds: §7 defaults accepted ("eventually yes").
3. Waste target 2%: accepted.
4. Remy persona: approved — mint as standing skill for weekly L3 reviews.
5. Spot-buy: approved with **auto-PO creation** (who/how to be detailed in WS-I design); hard requirement = live refreshable plan, inventory reflected the moment the PO is received (WS-I5).
6. Pins: both modes — perpetual OR N-week with re-confirmation, selectable per pin, expiry visible in FE.

Added same day: WS-J (three operating models first-class; machine inventory as event ledger).
