# Refill Post-Mortem — 2026-06-03

Source: Simran's consolidated feedback doc + live DB trace + tonight's conductor session.

Today's failures collapse into **5 root causes**. Most are pre-existing pipe/logic gaps that the aggressive full-capacity fills + manual swaps exposed.

---

## Root Cause 1 — Shared SKUs over-committed: "shows 0 but stock is there"

**Symptoms:** OMDCW YoPRO (3 physical, pickup 0) / Al Ain Water (19 physical, pickup 0); HUAWEI Hunter Ridges; AMZ-1068 Al Ain Water (14 in the morning → 0 after other Amazon machines confirmed, inventory still shows 37); VML Coke Zero / Dubai Popcorn; AMZ-1057.

**Why (confirmed in `v_dispatch_availability`):**

- `available_qty = LEAST(target, wh_stock_now − reserved_by_earlier)`.
- `reserved_by_earlier` is a window sum of **every earlier (by `dispatch_id`) unpacked warehouse Refill/Add-New** for the same `boonz_product_id + dispatch_date`.
- So whichever machine's lines were created/packed _first_ reserve the stock; **later dispatch_ids get whatever's left, down to 0** — purely by creation order, not priority.
- `pack_dispatch_line` _does_ decrement `warehouse_stock` and add to `consumer_stock` correctly. The "inventory still shows 37" is the team reading **physical total (warehouse_stock + consumer_stock)** while the _pickable_ `warehouse_stock` is already spoken for.
- The real trigger today: **total demand > stock for several shared SKUs.** Example measured tonight — Coca Cola Zero: WH 55u, demand 78u (AMZ "Coca Cola Mix" shelves split ~83% into Zero = 50u, + VML 28u). Dubai Popcorn similar.

**This is genuine scarcity made visible, not a display bug** — but the UX is misleading and the allocation is unfair (creation-order, not priority/velocity).

**Fix:**

- (Logic) Engine must gate refills on **`wh_available_pod`** at plan time — it already computes `procurement_gaps`, but the manual full-capacity fills bypassed it. Never dispatch more than WH can cover for a shared boonz.
- (Logic) Replace `reserved_by_earlier` creation-order reservation with a **priority/fair-share allocation** (by machine severity or velocity), so manual/late adds aren't auto-starved.
- (UX) Packing screen should say "reserved to {machines}", not just "committed".

---

## Root Cause 2 — Packed items never reach the dispatch list

**Symptoms:** VML whole refill missing from dispatch after packing + swaps; AMZ-1068 Vitamin Well Reload; AMZ-1057 Pepsi Black + Sunbites Cheese; OMDCW Al Ain 19 — all "packed but not in dispatch list".

**Why:**

- **The unmappable-REMOVE stitch bug** (separately logged) silently broke VML's whole commit tonight: `write_refill_plan` V5 rejected the Evian/Vitamin Well/Krambals&Zigi REMOVE lines ("Unknown boonz_product_name"), yet `confirm_stitched_plan` still flipped pod→stitched. Result: `pod_refill_plan` says stitched, `refill_plan_output` empty → nothing dispatches. This is exactly "packed/confirmed but dispatch empty."
- `pack_dispatch_line` **splits multi-batch picks into child `refill_dispatching` rows.** If the dispatch-list view filters or de-dupes incorrectly, child rows (Pepsi Black, Sunbites) disappear from the list even though packed.

**Fix:**

- (Logic) Stitch must **not** flip to stitched when `write_refill_plan` returns `validation_error` (atomic). And resolve multi-variant/combined REMOVE to a concrete boonz variant (or skip qty-0 REMOVE) so it stops rejecting.
- (Logic/FE) Audit the dispatch-list query for child-row visibility after multi-batch pack.

---

## Root Cause 3 — Driver ground recommendations ignored (stitch override)

**Symptoms:** OMDCW should have had more Mars (driver rec from prior visit) but the engine/stitch planned its own thing; many "Recommendation from driver on the ground" items never appear.

**Why:** `driver_feedback` captures these, but the **engine never ingests them** — the G5 "Track D" wiring was filed and never built. The engine plans purely from velocity + shelf state, so prior-visit ground truth is dropped every cycle.

**Fix:**

- (Logic) Wire `driver_feedback` / `v_driver_feedback_weight` into `engine_add_pod` as a demand signal (boost requested products) so driver asks persist across visits.

---

## Root Cause 4 — Wrong variant dispatched + rows for 0-stock products

**Symptoms:** AMZ-1068 Red Bull **Regular** packed but **Diet** shows in dispatch; Mindshare Vitamin Well **Care / Antioxidant / Zero Peach** generate packing rows with **0 inventory**; Vitamin Well **Upgrade** in stock but absent from refill.

**Why:**

- Variant resolution at stitch/pack picks the wrong `boonz_product_id` (Regular↔Diet) — a `product_mapping` / `pod_inventory` variant pin error.
- The engine recommends every mapped variant of a pod regardless of WH stock, so 0-stock variants still produce a row the driver can only skip. Mirror failure: a real in-stock variant (Upgrade) isn't mapped/visible so it never gets a row.

**Fix:**

- (Logic) Suppress refill/dispatch rows where the resolved boonz variant has `wh_available = 0`.
- (Data) Repin Red Bull and the Vitamin Well variant mappings; verify pod_inventory variant attribution.

---

## Root Cause 5 — Inventory accounting: phantom physical stock

**Symptoms:** "inventory not deducting", "shows 37 after packing 14", stock that's physically present but unpickable.

**Why:** `warehouse_stock` (pickable) decrements on pack into `consumer_stock` (reserved/in-transit). `consumer_stock` only drains on **receive/return**. If pickups aren't being received-back cleanly (or M2M/transfers aren't reconciled), `consumer_stock` accumulates and the "total" inventory view overstates pickable. Compounds RC1.

**Fix (D):** Audit the warehouse_stock → consumer_stock → pod_inventory chain for 2026-06-03; ensure pack→pickup→receive fully drains consumer_stock; reconcile the specific data corrections from Simran's doc (Vit Well Upgrade 2, Perrier ×5, Smart/Beetroot Hummus, Hunter ×4, Red Bull Regular, Pepsi Black, Sunbites Cheese, Krambals transfer, etc.).

---

## Fix priority

| #   | Fix                                                                 | Type  | Review    | Why first                                     |
| --- | ------------------------------------------------------------------- | ----- | --------- | --------------------------------------------- |
| 1   | Stitch: don't confirm on write error + resolve multi-variant REMOVE | Logic | Cody      | Silently kills whole-machine dispatches (RC2) |
| 2   | Engine: gate refills on wh_available; suppress 0-stock variant rows | Logic | Cody      | Stops RC1 + RC4 over-asks at the source       |
| 3   | Inventory reconcile WH↔pod for 2026-06-03 (D)                       | Data  | Dara/Cody | Restores trust in pickable numbers (RC5)      |
| 4   | Wire driver_feedback into engine demand (RC3)                       | Logic | Cody      | Persists ground truth                         |
| 5   | Fair-share allocation instead of dispatch_id order (RC1)            | Logic | Dara+Cody | Bigger redesign                               |
| 6   | Variant repin (Red Bull, Vitamin Well) (RC4)                        | Data  | —         | Targeted                                      |
| C   | Log today's missing/manual refills                                  | Data  | —         | Record accuracy                               |
