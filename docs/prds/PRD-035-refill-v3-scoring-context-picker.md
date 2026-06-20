# PRD-035 — Refill v3: relative scoring engine, flavor-aware stitch, session context, smart picker

**Author:** CS + Claude · **Date:** 2026-06-18 · **Status:** Draft for review
**Origin:** retrospective of the 2026-06-17 "monster" 3-hour refill (`BOONZ BRAIN/refill_retrospective_2026-06-17.md`).
**Principle:** the system must resolve **pod → in-stock flavor → real pickable stock** as a first-class step, score every shelf **relative to its machine**, and expose its own state up front. Stance is display-only, never a driver.

Routing: WS-A/B touch the engine (Dara design → Cody review). WS-C is the canonical stitch writer (Cody mandatory). WS-D is read-only (a view/RPC). WS-E is the picker. Each WS ships independently; suggested order at the end.

---

## WS-A — Relative machine score drives the ADD fill size (CS #1, part 1)

**Problem.** Fill quantity is driven by lifecycle stance + `stance_mult`. Result yesterday: Coca Cola Zero (score 101) and a 0-sales "DOUBLE DOWN" shelf both got filled hard; heroes labeled "WIND DOWN" nearly skipped. Quantity ignores how a shelf ranks _against the other shelves on the same machine_.

**Design.**

- Keep the existing **final_score** (it already compiles stance + global + local) but use it as a **relative rank within the machine**, not an absolute multiplier.
- Fill target = f(relative rank) × capacity-cover:
  - Top-ranked shelves → full cover (to capacity / full days-cover).
  - Mid → reduced cover.
  - **Low score + empty → a _low percentage_ fill** (don't pour capacity into a weak product just because it's empty). Low score + already stocked → little/no top-up.
- `stance` is removed from the quantity math; it stays as a display annotation only.
- 0 local sales (units_7d = 0 and v30 = 0) → no fill regardless of rank (today's "dead" guard, but now driven by sales not stance).

**Touches:** `compute_refill_decision`, `engine_add_pod`. **Open Q (A1):** the exact rank→fill curve (proposal: percentile bands — top third = 100% cover, middle third = ~60%, bottom third = ~30%, empty-and-bottom = floor only). Tune with CS.

---

## WS-B — Score-driven SWAP: optimize each slot for returns (CS #1, part 2)

**Problem.** A low-ranking product keeps its slot and just gets refilled, even when a better product would earn more there. Swaps today are triggered by stance (DEAD/ROTATE OUT), not by returns.

**Design.**

- For shelves whose product ranks **low** on the machine, evaluate whether a **higher-projected product** should take the slot (score the candidate's projected final_score in that slot vs the incumbent).
- If a materially better candidate exists (gap > threshold) and it's in stock, propose a **SWAP** (REMOVE incumbent + ADD_NEW better product) to maximize per-slot return.
- This replaces stance-based swap triggers with score/returns-based ones; reuse `find_substitutes_for_shelf` for candidates.

**Touches:** `engine_swap_pod`, `find_substitutes_for_shelf`. **Open Q (B1):** when a product is displaced because it ranks low _here_, does the engine try to **relocate it to a machine where it would rank higher** (true "better place for this product"), or simply drop it? **(B2):** swap trigger threshold (score gap + min candidate score).

---

## WS-C — Flavor-aware stitch: no silent drops, sibling fallback, alerts + notes (CS #3) — HEADLINE FIX

**Problem (confirmed bug, `bug_stitch_onshelf_variant_silent_drop`).** `stitch_pod_to_boonz` REFILL only fills the flavor **physically on the shelf**; if that flavor is out of WH stock it drops the line to **0 with no alert** (Red Bull, Healthy Cola, Hunter all shipped empty yesterday). The alert path uses raw split×WH so it disagrees with the line-builder.

**Design (priority order CS set):**

1. **Best:** quantity good _and_ correct boonz SKUs.
2. **Good (acceptable):** quantity good via an **in-stock sibling flavor of the same pod** when the ideal SKU is OOS.
3. **Worst (avoid):** empty shelf.

- So when the on-shelf/ideal flavor is OOS, **fall back to an in-stock sibling** of the same pod to keep quantity + visual good. Prefer this over leaving empty.
- **Always raise an alert** for every dropped/substituted line: what was dropped, why, what was substituted. Reconcile the line-builder and the alert-builder so they never disagree (no silent 0-fills).
- **Add a note** on the dispatch line documenting the substitution (e.g., "ideal SKU X out of stock → filled with sibling Y").

**Touches:** `stitch_pod_to_boonz` (canonical — **Cody mandatory**, forward `CREATE OR REPLACE` migration `phaseF_stitch_wh_aware_variant_fallback`), `procurement_alerts`, dispatch `comment`. **Note:** once this ships, the per-machine "map pod to only its in-stock flavor" hack used yesterday becomes unnecessary, and same-pod fills stay REFILL (no ADD_NEW mislabeling).

---

## WS-D — Session readiness / context load (CS #2)

**Problem.** The engine is blind: every plan/edit rediscovers IDs, mappings, WH stock, quarantine, reservations, on-shelf flavors, onboarding gaps — and failures only surface when hit (Barkthins quarantined, Al Ain reserved, Rice & Corn unmapped, mappings pointing at OOS flavors).

**Design.** A **session readiness snapshot** built once when a plan opens, resolving for every in-scope shelf:

- flavor currently on the shelf vs pickable WH per flavor (net of **reservations + quarantine**),
- whether the pod maps to **any in-stock flavor** (mapping health),
- onboarding gaps (pod product / mapping missing),
- expiry risk on the batch that would fill it.
- Output a single **"can fill / can't fill + why"** report before planning. The engine plans against it; edits read cached context instead of re-querying.

**Touches:** new read-only view/RPC (e.g., `get_refill_session_readiness(plan_date)`); leans on PRD-028 metrics (`v_wh_pickable`, velocity, expiry unification). Read-only → Cody fast-path.

---

## WS-E — Step 0 picker: P1-focused, area-clustered, sister-aware, VOX calendar (NEW)

**Problem.** Machine selection isn't trip-efficient and doesn't encode the VOX schedule.

**Design.**

- **P1-first:** select on real need (empty shelves, dead/low-runway, high local demand) — the P1 priority tier — scored, not stance-driven.
- **Area logic:** cluster the route by geography so the trip is efficient (define cluster key — see Open Q).
- **Sister-location pull-in:** when a machine is picked, pull in its **co-located sisters even if they're only P2**, so nearby machines are serviced together.
- **VOX calendar:**
  - **Wed AM & Fri AM = VOX days:** select **all VOX venue machines** + **2–3 non-VOX** (P1, nearest to the VOX route). **If the VOX machines are well-equipped** (above a fill/runway threshold), skip/reduce VOX and **focus on non-VOX** instead.
  - **Saturday = OFF** (delivery day): generate **no plan** (8pm Friday cron must not produce a Saturday plan).
  - Other days: normal P1 + area + sister selection.

**Touches:** `pick_machines_for_refill`, `build_draft_for_confirmed` cron (Saturday skip + VOX-day branch), `machines.venue_group` / location fields. **Open Q (E1):** cluster key — `venue_group`, `building_id`, or lat/long radius? **(E2):** "VOX well-equipped" threshold (e.g., every VOX shelf ≥ X% fill AND runway ≥ Y days). **(E3):** how the 2–3 non-VOX are chosen on VOX days (top P1 nearest the VOX cluster?). **(E4):** sister definition for P2 pull-in (same as cluster key?).

---

## Suggested sequence

1. **WS-C** (flavor-aware stitch) — removes silent drops + the manual repoint/relabel tax. Biggest immediate relief.
2. **WS-A** (relative-score fill sizing) + demote stance to display.
3. **WS-D** (session readiness) — makes the engine sighted; unblocks everything else.
4. **WS-E** (smart picker + VOX calendar + Saturday off).
5. **WS-B** (score-driven swap / slot optimization) — the returns-maximizing layer, last because it depends on A's scoring being trusted.

## Decisions needed from CS before build

- A1 rank→fill curve · B1 relocate-vs-drop displaced product · B2 swap threshold · D scope confirm · E1 cluster key · E2 VOX "well-equipped" rule · E3 non-VOX pick on VOX days · E4 sister definition.
