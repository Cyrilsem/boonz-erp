# What actually changed, and what is running the fleet today

19 Aug 2026. Answers three questions: what did the brain work change, did the app features fix the problems, and is today's performance v19 or v3.

---

## The one-line answer

**Every refill on the ground today was planned by v19.** v3 has never planned a single live line. It writes a parallel plan every night that nobody executes — for 19 Aug, v3 wrote 193 shadow rows while the 50 live rows the drivers actually worked came from v19.

We _are_ improving. But the improvements that reached the ground are the **guardrails, the visibility and the picker tuning** — not the quantity math. The quantity math is still v19, unchanged.

### Proof

| Check                         | Reading                                                                                                  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------- |
| Clusters authoritative for v3 | **0 of 10**                                                                                              |
| Real flips ever applied       | **0** (14 audit rows exist, all golden-fixture round-trips that flip and revert in the same transaction) |
| Live plan rows, 10–19 Aug     | 346 — all v19                                                                                            |
| Shadow v3 rows, same window   | 1,055 — all discarded                                                                                    |

⚠️ **A naming trap worth knowing.** The live nightly plan job is called `phaseF_stage1_prep_8pm_dubai` and it calls `build_draft_for_confirmed_v3`. The name says v3. Inside, it calls `engine_add_pod`, `engine_swap_pod`, `engine_finalize_pod` — the **v19** engines. The `_v3` suffix is the pipeline wrapper, not the brain. If anyone has been reading "v3" in the cron list and assuming the new brain is live, this is why.

---

## Map 1 — Brain changes and their impact today

"Live" = affects the plan your drivers ran this week. "Shadow" = runs, writes, changes nothing.

| #   | Change                                                    | What it does                                                    | State                      | Impact on today                                                                                                                                                     |
| --- | --------------------------------------------------------- | --------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Picker weight tuning** (`w_empty` 0.900 → 0.945)        | Empty shelves pull a machine onto the route harder              | **LIVE since 6 Aug**       | **Real.** The only v3-derived change that alters daily behaviour. Machines with empty shelves get visited sooner than they did two weeks ago.                       |
| 2   | **Slot lifecycle seeding** (nightly)                      | Auto-creates the plannable row for shelves that had none        | **LIVE**                   | **Real.** Directly attacks the ~93-invisible-shelves problem (G2). Shelf truth view now covers 656 shelves.                                                         |
| 3   | **Blocked-demand ledger** (nightly)                       | Logs every unit we wanted to place but couldn't                 | **LIVE**                   | **Real but passive.** 101 rows logged in August. Visibility only — it does not yet trigger buying.                                                                  |
| 4   | **Preflight invariants** (12 checks)                      | Catches bad plans before commit                                 | **LIVE, `warn` mode**      | **Partial.** It tells you; it does not stop you. Flipping to `block` (D-19) is waiting on an FE deploy.                                                             |
| 5   | **Sourcing model** (`boonz` vs `venue_team`)              | Per-product sourcing on mixed shelves                           | **LIVE, partly**           | **Real but manual.** 274 venue mappings across 28 machines — but you patched them by hand three times in one week. The model exists; the automatic upkeep does not. |
| 6   | **Weekly miners** (pick + edit history)                   | Learns your picking and editing judgment, proposes dial changes | **LIVE, minting for real** | **Blocked on you.** 14 proposals sitting pending. Nothing applies without your approval.                                                                            |
| 7   | **Scoreboard** (OSA, waste, WMAPE, adherence)             | Daily fleet measurement                                         | **LIVE**                   | **Measurement only.** 290 days computed. This is how we know v3 is losing.                                                                                          |
| 8   | **In-stock velocity** (kills censored demand)             | Sales ÷ hours actually in stock, not ÷ calendar days            | **SHADOW**                 | **None today.** This is the single biggest intended improvement and it has never sized a real line.                                                                 |
| 9   | **Service-level targets** (z-scores, μ+zσ)                | Sizes to a service level instead of a flat cover                | **SHADOW**                 | **None today.**                                                                                                                                                     |
| 10  | **Expiry ceiling**                                        | Never place more than the shelf can sell before expiry          | **SHADOW**                 | **None today.** The live expiry protection is PRD-113/114, not this.                                                                                                |
| 11  | **Substitution ladder** (never silent qty-0)              | variant → substitute → other WH → M2M → log it                  | **SHADOW**                 | **None today.** Live path still drops to `blocked_no_wh`.                                                                                                           |
| 12  | **Value-at-risk picker + day capacity**                   | Route by money at risk vs driver hours                          | **SHADOW**                 | **None today.**                                                                                                                                                     |
| 13  | **Facing rightsizing + rotation heartbeat**               | Proposes shelf-space changes weekly                             | **LIVE as proposals**      | **Blocked on you.** Proposes; never acts.                                                                                                                           |
| 14  | **Demand multipliers** (macro KPI × events × day-of-week) | Sizes up for known busy periods                                 | **SHADOW**                 | **None today.** Back-to-office campaign will not be sized for automatically.                                                                                        |
| 15  | **Cutover switch** (DR-1 / DR-1b)                         | Per-cluster flip, reversible, evidence-gated                    | **LIVE, flag-off**         | **Inert by design.** Refuses all 10 clusters.                                                                                                                       |

**Read the table this way:** rows 1–7 and 13 are why things feel better. Rows 8–12 and 14 — the actual new brain — have delivered nothing yet and will deliver nothing until a cluster flips.

---

## Map 2 — App and UI features: is the problem actually gone?

Honest column is the last one. None of these five has been observed working on a real machine after ship.

| PRD                                      | Problem it was built for                                                                                           | Shipped                                                                    | Is it fixed in the field?                                                                                                                                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **111** Pack-ahead toggle                | Plan dated tomorrow was invisible on `/field`; team packed off a PDF                                               | Today/Tomorrow toggle on packing screens                                   | ⛔ **Unverified.** No report, no fixture, no record the acceptance walk was ever run. Weakest of the five.                                                                                                              |
| **112** Driver substitution + Day Close  | VOXMCC-1005: venue had only Coconut, driver had no self-service path, needed you mid-route                         | "Change product" button + Day Close tab                                    | ⚠️ **Code proven, never used.** The live test was explicitly declined. Known open: the warehouse debit against the old batch is **never reversed** — only made visible.                                                 |
| **113** In-machine moves + expired guard | Same-machine swaps entered the return queue and would have credited phantom stock; FIFO ate expired units as sales | Move-within-machine chips, return button disabled, expired batches skipped | ⚠️ **Guard has never fired on a real leg.** Every live test was rolled back. Did find real past damage: **14 units across 3 batches consumed while expired — still unrepaired**, you owe a physical check of 3 shelves. |
| **114** Expiry visit checklist           | Plan says what to put in; nothing says what to check                                                               | Red/amber expiry checks on driver screens                                  | ⚠️ **Zero rows written in production.** No driver has tapped a chip. Meanwhile the fleet is carrying expired batches right now.                                                                                         |
| **115** Mid-pack edit safety             | NISSAN-0804, 14 Aug: removed rows resurrected, 19 warnings, stuck state                                            | Tombstone on removed rows, one refresh banner, safe Finish path            | ✅ **Strongest.** Fleet-wide query proves the bad state is now unrepresentable. But the headline fix — the resurrection killer — is proven by fixture only, never by a real push.                                       |

**The pattern:** we shipped five real fixes in eight days and verified all five against tests rather than against the fleet. That is not nothing — 115 in particular is solid — but "we don't have problems like we used to" is not yet a claim the data supports. It is a claim the _fixtures_ support.

**The counter-evidence is on the board right now:** 61 returns pending manager receive, unmoved for a week. 3 rows awaiting review. That queue is a live operational problem no PRD has touched.

---

## What I would do with the remaining hours of the window

1. **Do not flip anything.** The gate refuses all 10 clusters, and where v3 is measurable it is losing.
2. **Fix the measurement before the next window.** The v3-vs-v19 comparison scores different machines on different velocity bases — it is not a fair fight, in either direction. Until that is fixed we cannot tell whether v3 is genuinely worse or just measured worse.
3. **Clear the 14 pending miner proposals.** That is the learning loop, already live, stalled on approval.
4. **Get v3 planning in the six blind clusters** (ADDMIND, GRIT, LVLUP, VML, VOX, WPP). They have zero v3 rows, so waiting changes nothing — they need to be brought into scope deliberately.
5. **Close the 61-return queue** and settle the 14 expired units from PRD-113.
