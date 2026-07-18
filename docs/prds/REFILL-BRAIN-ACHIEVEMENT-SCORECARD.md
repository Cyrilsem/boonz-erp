# Refill Brain — Achievement Scorecard (vs the original audit list)

Date: 2026-07-09. Maps the original Step-2 audit (14 edge cases + systemic root causes) to what has actually been built across Waves 0–2.

**Legend**

- ✅ **Live** — shipped and active (detection/guard running, or verified-correct).
- 🟦 **Dark** — built, proven safe (flag-OFF = byte-identical), awaiting a CS enable decision.
- 🧊 **Held** — spec'd & ready, gated only on an engine-freeze window (no other blocker).
- 🔎 **Diagnosed** — root-caused with evidence; fix is a data/ops task, not engine code.
- ⬜ **Not started** — Wave 3+ (unauthored).

---

## The 14 edge cases

| #   | Case                                      | Status | What shipped / where it stands                                                                                                                                                                                                |
| --- | ----------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Add when shelf performing well            | ✅     | Was already correct; unchanged.                                                                                                                                                                                               |
| 2   | Add when less performing                  | 🟦     | **089** absolute-velocity floor + min-facing shipped dark. **Finding:** on real data this is largely theoretical (throttled shelves genuinely sell <0.2/day) — don't tune to bind.                                            |
| 3   | Expired stock on a performing shelf       | 🟦→🧊  | **091** expiry signal **LIVE** (`v_shelf_expiry_risk`, 80 shelves flagged). Rotation itself = **095**, engine-freeze-held.                                                                                                    |
| 4   | Expired stock, not performing (replace)   | 🧊     | **095** expiry-swap trigger; input (091) ready; held for freeze.                                                                                                                                                              |
| 5   | Not performing → swap                     | ✅     | Already existed; **094** improves its sizing (held).                                                                                                                                                                          |
| 6   | Shelf low/empty but no warehouse stock    | 🟦     | **092** `compute_nowh_proposals` **LIVE** (substitute / M2M / procurement; 12/12 validated). Engine auto-wiring held.                                                                                                         |
| 7   | Swap product locations within a pod       | 🧊     | **096** within-pod relocation; needs hv→lv pairing rule; held.                                                                                                                                                                |
| 8   | Move a product machine→machine            | 🟦→🧊  | **092** now emits **M2M proposals**; autonomous execution held (096/Wave-3).                                                                                                                                                  |
| 9   | Rebalance the ecosystem to sell better    | ⬜     | Wave 3 (strategic layer), unauthored.                                                                                                                                                                                         |
| 10  | **Cap stuck on the old product**          | 🧊     | **094** re-spec'd vs the live engine; bug **re-confirmed** in Passes 1 & 2; fix ready; held for freeze.                                                                                                                       |
| 11  | **Warehouse quantity wrong / "empty"**    | ✅🟦   | **Biggest win.** Availability truth (**079** `wh_is_pickable` + held-state) LIVE; FEFO + reservation (**080**) dark; pack-RPC guard (**081**) in WARN; conservation gate (**077**) LIVE; planned/filled split (**082**) dark. |
| 12  | Niche SKU not concentrated for visibility | 🟦     | **090** merchandising-fill dark. **Finding:** facings already meet the floor. The SF-Pancake blocker (quarantined stock) is now releasable via **PRD-098** `approve_return` — no longer stuck.                                |
| 13  | Wrong SKU "pinned" to a shelf             | ✅     | **084** pre-pack drift guard LIVE (advisory) — catches real drift; blocking tier held.                                                                                                                                        |
| 14  | Consignment / venue-sourced SKUs (new)    | 🟦     | **093-A** `is_consignment` columns LIVE; VOX seed prepared; engine gating (Part B) held.                                                                                                                                      |

## Systemic root causes & the referee

| Item                                      | Status | What shipped                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **The referee (net-new capability)**      | ✅     | **076** shadow-diff harness + **077** conservation gate + **078** golden baseline — a way to prove any change is safe _before_ it ships. Didn't exist before.                                                                                                                                                                                                            |
| Cause A — two engine generations          | ✅     | **083** orphan Family-B engine deprecated (redirect live; DROP after 90d).                                                                                                                                                                                                                                                                                               |
| Cause C — the warehouse hole              | ✅🟦   | Addressed by 079/080/081/082 (see case 11).                                                                                                                                                                                                                                                                                                                              |
| Cause G — finalize silently un-approves   | ✅     | **085** verified locked + regression registered.                                                                                                                                                                                                                                                                                                                         |
| Cause I — stale-planogram drift           | ✅     | **084** detection live.                                                                                                                                                                                                                                                                                                                                                  |
| Cause J — quarantine hides real stock     | ✅     | **SOLVED (PRD-098).** Root cause = returns that can't reconcile to a known batch land `dispatch_return_unverified` with no release path. Fix: `approve_return`/`reject_return` (inventory-manager gated) + pending views + daily aging alert (`cron_pending_return_alert`). Backlog (24 ongoing + 19 recoverable legacy) queued for the manager; 23 legacy to write off. |
| Cause K — planned vs filled qty collapsed | 🟦     | **082** split shipped dark.                                                                                                                                                                                                                                                                                                                                              |
| §3b — FE pack-bypass (BUG-006)            | 🟦     | **081** guard in WARN; ENFORCE held on one clean packing cycle.                                                                                                                                                                                                                                                                                                          |

---

## Tally

- **Diagnosis: 100%.** Every case + systemic cause root-caused with live evidence (the original ask).
- **Wave 0 (foundation + warehouse spine): 10/10 shipped.** The referee + the warehouse-integrity work — the highest-leverage, hardest part — is done.
- **Wave 1 (ADD): 3/5 shipped** (091 & 092 as _live_ infra; 089/090 dark; 093-A live). 091/092/093-B engine-wiring held.
- **Wave 2 (SWAP): 0/4 code, but all spec'd**; 094 (keystone) re-spec'd & confirmed, held only for a freeze window.
- **Not started: Wave 3–5** (ecosystem rebalance, FE polish, hardening).

## Honest headline

The **engineering and de-risking are largely done**; the **live behaviour** is mostly gated behind two deliberate decisions, not more work: (1) **CS enabling** the dark flags after reviewing deltas, and (2) **one engine-freeze window** to land the SWAP fixes (esp. 094). Almost nothing is "stuck" — it's staged, safe, and reversible.
