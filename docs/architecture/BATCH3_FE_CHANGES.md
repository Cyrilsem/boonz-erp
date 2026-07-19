# FE_CHANGES — Batch 3 (RC-04 phase 1): rewire direct table writes onto canonical RPCs

**Author:** STAX · **Date:** 2026-07-18 · **Repo snapshot:** `/home/claude/boonz/boonz-erp`
**DB (read-only, signature verification):** Supabase `eizcexopcuoycuosittm`
**Scope:** FE `.update` / `.insert` / `.upsert` / `.delete` on protected tables (`refill_dispatching`, `warehouse_inventory`, `refill_plan_output`, `product_mapping`, `machines`) → canonical SECURITY DEFINER RPCs.

> **DEPLOY-TOGETHER NOTICE.** This FE change set **deploys together with the Batch-2 FE in a single push** (one Vercel deploy, one `/goal`). It is **backward-safe**: every RPC it calls (`pack`/`receive`/`pickup`/`confirm`/`approve`/`writeoff`) already exists on the **current live backend** (batch-0/1/2). Nothing here depends on a not-yet-applied migration. The one place that leans on Batch-4 semantics — `receive_dispatch_line` requiring `packed+picked_up` and doing the real WH deduction — is called the same way today and today's function is a strict subset; **Batch-4 backend applies before this FE goal runs**, so the hardened contract is in force at deploy time.

---

## 1. The highest-priority kill — DailyDispatchingTab "Mark All" (phantom stock minting)

**File:** `src/app/(app)/refill/DailyDispatchingTab.tsx`

### What was wrong (verified live in the snapshot)
`handleBulkUpdate` did a **raw `UPDATE refill_dispatching`** flipping `packed` / `picked_up` / `dispatched` to `true` for every included line, then — for the dispatched action — called `receive_all_dispatches_for_machine`.

The raw flip set `packed=true` **without** the `warehouse_stock → consumer_stock` move that `pack_dispatch_line` performs. `receive_dispatch_line` (which `receive_all_dispatches_for_machine` loops) credits `pod_inventory` by **draining `consumer_stock`**. With no real pack, `consumer_stock` was never credited, so the receive path **credited pod_inventory while deducting nothing from the warehouse = phantom stock minting.** Confirmed by reading `pack_dispatch_line` (moves WH→consumer) and `receive_dispatch_line` (draws from `consumer_stock`; when none exists it credits pod with no WH draw).

### What it does now (each action → canonical RPC, no raw write)
| Button | Old (raw) | New (canonical) | Notes |
|---|---|---|---|
| **Mark All Packed** | `UPDATE ... packed=true` | `confirm_machine_packed(p_machine_name, p_dispatch_date, p_packed_by:null, p_reason, p_final:true)` | Finalize **gate** — it does **not** fabricate `line.packed`. It verifies every included line is genuinely packed (via the field packing PWA / `pack_dispatch_line`) or `not_filled`/`skipped`; if unpacked lines remain it returns `{status:'blocked'}` (surfaced to console/CS). The one-click *fake pack* is now impossible. |
| **Mark All Picked Up** | `UPDATE ... packed,picked_up=true` | `mark_picked_up(p_dispatch_ids)` | Bulk (array) RPC. Only flips lines already `packed=true`; un-packed ids come back as `not_packed_ids` untouched. No fabrication. |
| **Mark All Dispatched** | `UPDATE ... packed,picked_up,dispatched=true` + `receive_all(...)` | `receive_all_dispatches_for_machine(p_machine_id, p_dispatch_date, p_use_filled_as_received:true)` | Credits pod from the **actual `filled_quantity`** and does the real WH move; **never** a planned-qty credit. Processes only lines drivers already set `dispatched=true`. |

**Signature confirmed live:** `confirm_machine_packed(text,date,uuid,text,boolean)`, `mark_picked_up(uuid[])`, `receive_all_dispatches_for_machine(uuid,date,boolean)`.

### UX notes for CS (picture the change)
- The three buttons look and behave the same for the **happy path**: warehouse packs in the field PWA → admin clicks *Mark All Packed* (now a confirmation, not a fabrication) → *Mark All Picked Up* → *Mark All Dispatched* materializes stock at the real filled quantity.
- **Behavioural change to know:** *Mark All Packed* can no longer "complete" a machine whose lines were never actually packed in the field. If the field team hasn't packed, the button no-ops with a blocked reason instead of silently faking it (and silently teeing up a phantom credit). This is the intended kill. Empty shelves are still fillable — the real pack path (`pack_dispatch_line` with picks in the packing PWA) is untouched.
- **Keyboard-speed preserved:** still one click per machine per stage; `mark_picked_up` is a single bulk call.

### Backend follow-up flagged (does not block this deploy)
- *Mark All Dispatched* relies on lines already being `dispatched=true` (driver-set). There is **no canonical `mark_dispatched_for_machine` RPC** to flip that flag from the admin monitor. Today the driver flow sets it; the admin button "receives what drivers dispatched." A canonical `dispatch_all_for_machine` (or extend `receive_all` to also mark dispatched) is a **Batch-5** nicety, not a blocker.

---

## 2. Driver trips page — filled_quantity/dispatched overwrite

**File:** `src/app/(field)/field/trips/[machineId]/page.tsx`

**What was wrong:** `handleSubmit` raw-`UPDATE`d `refill_dispatching` setting `filled_quantity`, `dispatched=true`, and `comment` directly — clobbering the numbers `pack_dispatch_line` had written and crediting nothing/deducting nothing correctly.

**Now:** confirming a fill at the machine **is a receive**. Each confirmed line loops the canonical `receive_dispatch_line(p_dispatch_id, p_filled_quantity)` (records the real filled qty, credits `pod_inventory`, returns the unfilled delta to WH — mirrors the reference implementation in `dispatching/[machineId]/page.tsx`). The comment is persisted via the canonical `update_dispatch_comment` RPC (already used elsewhere). "already received" errors are treated as idempotent.

**Backward-safe:** `receive_dispatch_line` + `update_dispatch_comment` both live today.

---

## 3. Refill plan review — approve path

**File:** `src/components/RefillPlanReview.tsx`

**What was wrong:** `handlePlanMachine` raw-`UPDATE`d `refill_plan_output` (`operator_status='approved'|'rejected'`) then explicitly called `push_plan_to_dispatch`.

**Now (approve):** the status flip is the canonical `approve_refill_plan(p_plan_date, p_machine_names:[machineName])`, which sets `operator_status='approved'` and fires `trg_fire_dispatch_on_approval → push_plan_to_dispatch`. The explicit `push_plan_to_dispatch` call is **kept** (idempotent; preserves the existing dispatch-result toast — same double-safe behaviour as today).
**Reject:** flagged — see §5 (no canonical reject RPC exists; left as-is with TODO, capability preserved).

> Minor: `approve_refill_plan` owns the status/`reviewed_at`; `operator_comment` on approve is now written by the RPC path rather than the FE. If product wants the operator's free-text comment persisted on approve, that's a small RPC-arg follow-up, not a regression of the reject path (which still writes the comment).

---

## 4. Expiry write-off

**File:** `src/app/(field)/field/expiry/page.tsx`

**What was wrong:** `handleRemove` raw-`UPDATE`d `warehouse_inventory` `status='Expired'` — an un-audited stock write-off. **Also latent-bug:** the query selected/filtered a **non-existent column `inventory_id`** (the real PK is `wh_inventory_id`, confirmed via `information_schema`).

**Now:** routes to the canonical `warehouse_expire_writeoff(p_wh_inventory_id, p_reason, p_caller_id:null)` (role-gated, requires a ≥10-char reason, records the write-off). The select + row mapping were corrected to source the local `inventory_id` field from the real `wh_inventory_id` column so the RPC receives a valid UUID (minimal, required for the write to function — no other read behaviour changed).

**Backward-safe:** `warehouse_expire_writeoff` lives today.

---

## 5. The 23 write sites — full disposition

22 direct-write anchors were detected across 11 files (RefillPlanReview `:215` carries **two** logical dispositions — approve *rewired* + reject *flagged* — reconciling to the "23 sites"). Detection method: `.from("<protected>")` followed within-window by `.update/.insert/.upsert/.delete`, verified by reading each site.

| # | File : line | Table | Op | Disposition |
|---|---|---|---|---|
| 1a | `refill/DailyDispatchingTab.tsx:320` | refill_dispatching | update | **REWIRED** → `confirm_machine_packed` / `mark_picked_up` / `receive_all_dispatches_for_machine` (phantom-mint kill) |
| 2 | `field/trips/[machineId]/page.tsx:258` | refill_dispatching | update | **REWIRED** → `receive_dispatch_line` (+ `update_dispatch_comment`) |
| 3a | `components/RefillPlanReview.tsx:215` (approve) | refill_plan_output | update | **REWIRED** → `approve_refill_plan` |
| 3b | `components/RefillPlanReview.tsx:215` (reject branch) | refill_plan_output | update | **FLAGGED** — no `reject_refill_plan` RPC; left as-is + TODO |
| 4 | `components/RefillPlanReview.tsx:249` | refill_plan_output | update | **FLAGGED** — no per-row reject RPC; left as-is + TODO |
| 5 | `field/expiry/page.tsx:139` | warehouse_inventory | update | **REWIRED** → `warehouse_expire_writeoff` (+ column fix) |
| 6 | `field/config/product-mapping/page.tsx:450` | product_mapping | delete | **FLAGGED** — no mapping RPC; TODO |
| 7 | `field/config/product-mapping/page.tsx:465` | product_mapping | delete | **FLAGGED** — no mapping RPC; TODO |
| 8 | `field/config/product-mapping/page.tsx:476` | product_mapping | insert | **FLAGGED** — no mapping RPC; TODO |
| 9 | `field/config/product-mapping/page.tsx:494` | product_mapping | update | **FLAGGED** — no mapping RPC; TODO |
| 10 | `field/config/product-mapping/page.tsx:503` | product_mapping | upsert | **FLAGGED** — no mapping RPC; TODO |
| 11 | `field/config/product-mapping/page.tsx:582` | product_mapping | delete | **FLAGGED** — no mapping RPC; TODO |
| 12 | `field/config/product-mapping/page.tsx:587` | product_mapping | insert | **FLAGGED** — no mapping RPC; TODO |
| 13 | `field/config/product-mapping/page.tsx:628` | product_mapping | upsert | **FLAGGED** — no mapping RPC; TODO |
| 14 | `field/config/machines/page.tsx:603` | machines | update | **FLAGGED** — no full-field `update_machine` RPC; TODO |
| 15 | `field/config/machines/page.tsx:704` | machines | insert | **FLAGGED** — `add_new_machine` misses contact/venue_group/pod_address (would drop fields); TODO |
| 16 | `field/config/machines/page.tsx:765` | machines | insert (CSV bulk) | **FLAGGED** — no bulk machine-insert RPC; TODO |
| 17 | `admin/machines/page.tsx:234` | machines | update (status bulk) | **FLAGGED** — no `set_machine_status` RPC; TODO |
| 18 | `admin/machines/page.tsx:317` | machines | update (edit) | **FLAGGED** — no field-scoped `update_machine` RPC; TODO |
| 19 | `app/pods/page.tsx:692` | machines | update (edit) | **FLAGGED** — no field-scoped `update_machine` RPC; TODO |
| 20 | `components/config/MachineSetupConfigTab.tsx:273` | machines | update (setup fields) | **FLAGGED** — no machine-setup RPC; TODO |
| 21 | `field/packing/[machineId]/page.tsx:1372` | refill_dispatching | delete | **FLAGGED** — hard-delete of stale un-packed slices for OB-2 respawn; `remove_dispatch_row` soft-cancels (collides w/ `prevent_duplicate_unstarted_dispatch`); TODO |
| 22 | `field/dispatching/[machineId]/page.tsx:535` | refill_dispatching | delete | **FLAGGED** — driver-context delete; `remove_dispatch_row` forbids driver role; needs driver-safe cancel RPC; TODO |

**Summary:** 4 rewired (5 counting the approve/reject split), 18 flagged-needs-backend (all left functional with an in-code `TODO(Batch 5 / RC-04)` comment — no capability removed, nothing broken).

### Why the flagged sites were NOT force-fit (constitutional / CS-rule reasoning)
- **`product_mapping`** — no canonical write RPC exists anywhere in `pg_proc` (only `auto_fill_machine_mapping`, a maintenance trigger). Inventing one is Batch-5 backend work; the task forbids inventing backend here.
- **`machines` inserts** — `add_new_machine(p_pod_number,p_official_name,p_location_type,p_pod_location,p_status,p_include_in_refill,p_installation_date,p_notes)` does **not** accept `contact_person/email/phone`, `venue_group`, or `pod_address`. Routing there would **silently drop** those fields — a destructive change, forbidden by CS Hard Rules.
- **`machines` updates (status / arbitrary / setup fields)** — no `set_machine_status` or field-scoped `update_machine` RPC exists. `set_machine_warehouse` only touches warehouse assignment (none of these sites edit warehouse assignment). `repurpose_machine`/`rename_machine` are identity transitions, not field edits.
- **`refill_plan_output` reject** — `approve_refill_plan` only approves; there is no `reject_refill_plan`. Reject left as-is to preserve the capability.
- **`refill_dispatching` deletes** — `remove_dispatch_row` is role-gated ("not allowed for driver") and soft-cancels rather than deletes, which collides with the OB-2 respawn / `prevent_duplicate_unstarted_dispatch` uniqueness. Rewiring risks breaking the driver + re-pack flows. Left as-is pending a driver-safe / respawn-safe canonical RPC.

---

## 6. Reviewer must-run commands

```bash
# 1. Typecheck (authoritative — run with node_modules present)
npx tsc --noEmit

# 2. Production build
npm run build

# 3. Lint
npm run lint
```

**Ambient-stub typecheck performed here (no node_modules in the snapshot):** a `declare module "react"` shim + `declare module "*"` wildcard + `lib:["ES2020","DOM","DOM.Iterable"]`, `files` = the 4 rewired components. Result: the changed files produce the **exact same 4-error profile as their originals** (`TS2322` JSX `key`, `TS2347` unshimmed hook, `2×TS2503` `React` namespace) — all pre-existing stub artifacts on unchanged lines. **My edits introduced zero new type errors.** The reviewer's `npx tsc --noEmit` (with real `@types/react`) is the authoritative gate.

### Manual QA focus for the reviewer
1. **Daily Dispatching → Mark All Packed** on a machine whose lines were NOT packed in the field PWA → expect a no-op/blocked (console warn), **no** phantom pod credit.
2. **Mark All Dispatched** on a machine the drivers already dispatched → pod credited at **filled** qty, warehouse decremented; verify no WH double-count vs. the pack move.
3. **Driver trips → submit** → line received (pod credited, unfilled delta returned to WH), comment persisted.
4. **Refill plan review → Approve** → status approved + dispatch pushed (toast unchanged).
5. **Expiry → Remove** → row written off via RPC; confirm the row actually resolves now (the `inventory_id`→`wh_inventory_id` column fix).

---

## 7. Files changed (staged under `batch3/fe/`, same relative paths)

**Rewired (canonical RPCs):**
- `src/app/(app)/refill/DailyDispatchingTab.tsx`
- `src/app/(field)/field/trips/[machineId]/page.tsx`
- `src/components/RefillPlanReview.tsx`
- `src/app/(field)/field/expiry/page.tsx`

**Flagged (TODO added, left functional):**
- `src/app/(field)/field/config/product-mapping/page.tsx`
- `src/app/(field)/field/config/machines/page.tsx`
- `src/app/(app)/admin/machines/page.tsx`
- `src/app/(app)/app/pods/page.tsx`
- `src/components/config/MachineSetupConfigTab.tsx`
- `src/app/(field)/field/packing/[machineId]/page.tsx`
- `src/app/(field)/field/dispatching/[machineId]/page.tsx`

Unified diffs for all of the above are inline in §8.

---

## 8. Unified diffs

<!-- BEGIN DIFFS -->
```diff
===== src/app/(app)/refill/DailyDispatchingTab.tsx =====
--- a/src/app/(app)/refill/DailyDispatchingTab.tsx	2026-07-18 14:47:02.520424870 +0000
+++ src/app/(app)/refill/DailyDispatchingTab.tsx	2026-07-18 14:47:43.697574637 +0000
@@ -296,47 +296,79 @@
 
   // ── Bulk update handler ──────────────────────────────────────────────────
 
+  // RC-04 (Batch 3): the bulk "Mark All ..." actions used to raw-UPDATE
+  // refill_dispatching (packed/picked_up/dispatched), which faked the pack
+  // WITHOUT the warehouse_stock -> consumer_stock move that pack_dispatch_line
+  // performs. receive_all_dispatches_for_machine then credited pod_inventory
+  // with NO warehouse deduction = phantom stock minting. All three actions now
+  // route through canonical RPCs so backend invariants (and the
+  // enforce_canonical_dispatch_write guard) hold and no pod credit ever happens
+  // without a real warehouse move.
+  //
+  // Backward-safe: confirm_machine_packed / mark_picked_up /
+  // receive_all_dispatches_for_machine all exist on the current live backend
+  // (batch-0/1/2). Batch-4 only hardens receive to require packed+picked_up and
+  // do the real WH deduction; this code already respects that contract.
   async function handleBulkUpdate(
-    machineId: string,
+    m: MachineSummary,
     field: "packed" | "picked_up" | "dispatched",
   ) {
+    const machineId = m.machine_id;
     setUpdatingMachine(machineId);
     try {
       const supabase = createClient();
-      // Build the update payload: set the target field and all preceding fields to true
-      const updatePayload: Record<string, boolean> = {};
+
       if (field === "packed") {
-        updatePayload.packed = true;
+        // Canonical pack-finalize gate. This does NOT fabricate line.packed:
+        // it verifies every included line is genuinely packed (via the field
+        // packing PWA / pack_dispatch_line) or explicitly not_filled/skipped,
+        // then records the machine-level confirmation. If lines are still
+        // unpacked it returns { status: 'blocked' } — surfaced to the admin so
+        // the phantom "one-click fake pack" is impossible.
+        const { data, error } = await supabase.rpc("confirm_machine_packed", {
+          p_machine_name: m.official_name,
+          p_dispatch_date: queryDate,
+          p_packed_by: null,
+          p_reason: "Admin bulk pack confirmation from Daily Dispatching tab",
+          p_final: true,
+        });
+        const result = data as { status?: string; message?: string } | null;
+        if (error) {
+          console.error("[DailyDispatching] confirm_machine_packed error:", error);
+        } else if (result?.status === "blocked") {
+          console.warn(
+            "[DailyDispatching] pack blocked — unpacked lines remain:",
+            result.message,
+          );
+        }
       } else if (field === "picked_up") {
-        updatePayload.packed = true;
-        updatePayload.picked_up = true;
+        // Canonical bulk pickup. mark_picked_up only flips lines that are
+        // genuinely packed=true (Article 5 state machine); un-packed ids are
+        // returned as not_packed_ids and left untouched — no fabrication.
+        const dispatchIds = m.lines.map((l) => l.dispatch_id);
+        const { error } = await supabase.rpc("mark_picked_up", {
+          p_dispatch_ids: dispatchIds,
+        });
+        if (error) {
+          console.error("[DailyDispatching] mark_picked_up error:", error);
+        }
       } else if (field === "dispatched") {
-        updatePayload.packed = true;
-        updatePayload.picked_up = true;
-        updatePayload.dispatched = true;
-      }
-
-      await supabase
-        .from("refill_dispatching")
-        .update(updatePayload)
-        .eq("machine_id", machineId)
-        .eq("dispatch_date", queryDate)
-        .eq("include", true);
-
-      // B2: when admin marks all dispatched, also materialize inventory —
-      // pod_inventory rows + return any underfilled units back to WH.
-      if (field === "dispatched") {
-        const { error: rpcErr } = await supabase.rpc(
+        // Canonical receive: credits pod_inventory from the ACTUAL filled
+        // quantity and moves warehouse stock (drains consumer_stock / returns
+        // the unfilled delta). Only processes lines drivers already marked
+        // dispatched=true. NEVER a planned-qty pod credit.
+        const { error } = await supabase.rpc(
           "receive_all_dispatches_for_machine",
           {
             p_machine_id: machineId,
             p_dispatch_date: queryDate,
+            p_use_filled_as_received: true,
           },
         );
-        if (rpcErr) {
+        if (error) {
           console.error(
             "[DailyDispatching] receive_all_dispatches_for_machine error:",
-            rpcErr,
+            error,
           );
         }
       }
@@ -413,7 +445,7 @@
         disabled={isUpdating}
         onClick={(e) => {
           e.stopPropagation();
-          handleBulkUpdate(m.machine_id, c.field);
+          handleBulkUpdate(m, c.field);
         }}
         style={{
           fontSize: 12,

===== src/app/(field)/field/trips/[machineId]/page.tsx =====
--- src/app/(field)/field/trips/[machineId]/page.tsx.orig	2026-07-18 14:47:02.523491718 +0000
+++ src/app/(field)/field/trips/[machineId]/page.tsx	2026-07-18 14:47:55.533574366 +0000
@@ -251,20 +251,35 @@
     setSubmitting(true);
     const supabase = createClient();
 
-    const updates = lines
-      .filter((l) => l.confirmed)
-      .map((l) =>
-        supabase
-          .from("refill_dispatching")
-          .update({
-            filled_quantity: l.filled_quantity,
-            dispatched: true,
-            comment: l.comment.trim() || null,
-          })
-          .eq("dispatch_id", l.dispatch_id),
-      );
+    // RC-04 (Batch 3): this used to raw-UPDATE refill_dispatching, setting
+    // filled_quantity + dispatched=true directly and clobbering the numbers
+    // pack_dispatch_line had written. Confirming a fill at the machine is a
+    // RECEIVE — route each confirmed line through receive_dispatch_line, which
+    // records the actual filled quantity, credits pod_inventory, and returns
+    // the unfilled delta to the warehouse (real WH move, no phantom credit).
+    // The comment is persisted via the canonical update_dispatch_comment RPC,
+    // matching the field dispatching page. Backward-safe: both RPCs exist on
+    // the current live backend.
+    const confirmed = lines.filter((l) => l.confirmed);
+    for (const l of confirmed) {
+      const { error } = await supabase.rpc("receive_dispatch_line", {
+        p_dispatch_id: l.dispatch_id,
+        p_filled_quantity: l.filled_quantity,
+      });
+      if (error) {
+        // Idempotent: a line already received in a prior submit is not an error.
+        if (!(error.message ?? "").includes("already received")) {
+          console.error("[Trips] receive_dispatch_line error:", error);
+        }
+      }
+      if (l.comment.trim()) {
+        await supabase.rpc("update_dispatch_comment", {
+          p_dispatch_id: l.dispatch_id,
+          p_comment: l.comment.trim(),
+        });
+      }
+    }
 
-    await Promise.all(updates);
     router.push("/field/trips");
   }
 

===== src/components/RefillPlanReview.tsx =====
--- a/src/components/RefillPlanReview.tsx	2026-07-18 14:47:02.526358720 +0000
+++ src/components/RefillPlanReview.tsx	2026-07-18 14:52:05.929568639 +0000
@@ -211,27 +211,49 @@
     setPlanProcessing((prev) => new Set([...prev, machineName]));
     const supabase = createClient();
     const comment = planComments[machineName] ?? "";
-    await supabase
-      .from("refill_plan_output")
-      .update({
-        operator_status: status,
-        reviewed_at: new Date().toISOString(),
-        operator_comment: comment || null,
-      })
-      .eq("machine_name", machineName)
-      .eq("operator_status", "pending");
 
-    if (status === "approved" && planDate) {
-      const { data: dispatched, error: pushError } = await supabase.rpc(
-        "push_plan_to_dispatch",
-        {
-          p_plan_date: planDate,
-          p_machine_name: machineName,
-        },
-      );
-      // v7 returns jsonb ({ status, lines_pushed, ... }), not a number (PRD-072)
-      setPlanToast(pushResultToToast(dispatched, pushError?.message));
-      setTimeout(() => setPlanToast(null), 5000);
+    if (status === "approved") {
+      // RC-04 (Batch 3): approving used to raw-UPDATE refill_plan_output
+      // (operator_status='approved') and then call push_plan_to_dispatch
+      // explicitly. The status flip is now the canonical approve_refill_plan
+      // RPC, which sets operator_status='approved' and fires
+      // trg_fire_dispatch_on_approval -> push_plan_to_dispatch. Backward-safe:
+      // approve_refill_plan exists on the current live backend.
+      const { error: approveErr } = await supabase.rpc("approve_refill_plan", {
+        p_plan_date: planDate,
+        p_machine_names: [machineName],
+      });
+      if (approveErr) {
+        setPlanToast(`Approve failed: ${approveErr.message}`);
+        setTimeout(() => setPlanToast(null), 5000);
+      } else if (planDate) {
+        // Idempotent explicit push preserves the existing dispatch-result toast
+        // (push_plan_to_dispatch no-ops if the approval trigger already pushed).
+        const { data: dispatched, error: pushError } = await supabase.rpc(
+          "push_plan_to_dispatch",
+          {
+            p_plan_date: planDate,
+            p_machine_name: machineName,
+          },
+        );
+        // v7 returns jsonb ({ status, lines_pushed, ... }), not a number (PRD-072)
+        setPlanToast(pushResultToToast(dispatched, pushError?.message));
+        setTimeout(() => setPlanToast(null), 5000);
+      }
+    } else {
+      // TODO(Batch 5 / RC-04): needs a canonical reject_refill_plan RPC.
+      // No RPC currently rejects refill_plan_output rows at machine level, so
+      // this direct UPDATE is intentionally LEFT AS-IS to avoid breaking the
+      // reject capability. Replace with the canonical RPC once it exists.
+      await supabase
+        .from("refill_plan_output")
+        .update({
+          operator_status: status,
+          reviewed_at: new Date().toISOString(),
+          operator_comment: comment || null,
+        })
+        .eq("machine_name", machineName)
+        .eq("operator_status", "pending");
     }
 
     setPlanRows((prev) => prev.filter((r) => r.machine_name !== machineName));
@@ -245,6 +267,9 @@
 
   async function handlePlanRejectLine(id: string) {
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): needs a canonical reject_refill_plan (per-row) RPC.
+    // Left as a direct UPDATE for now — no canonical rejecter exists and we must
+    // not break per-line reject. Rewire once the RPC lands.
     await supabase
       .from("refill_plan_output")
       .update({

===== src/app/(field)/field/expiry/page.tsx =====
--- a/src/app/(field)/field/expiry/page.tsx	2026-07-18 14:47:02.529037888 +0000
+++ src/app/(field)/field/expiry/page.tsx	2026-07-18 14:50:05.253571399 +0000
@@ -71,7 +71,7 @@
       .from("warehouse_inventory")
       .select(
         `
-        inventory_id,
+        wh_inventory_id,
         batch_id,
         wh_location,
         warehouse_stock,
@@ -91,7 +91,11 @@
     const mapped: InventoryRow[] = data.map((row) => {
       const p = row.boonz_products as unknown as { boonz_product_name: string };
       return {
-        inventory_id: row.inventory_id,
+        // RC-04 (Batch 3): the real PK column is wh_inventory_id; the prior
+        // select referenced a non-existent `inventory_id` column. Source the
+        // local field from the real column so warehouse_expire_writeoff gets a
+        // valid id.
+        inventory_id: row.wh_inventory_id,
         boonz_product_name: p.boonz_product_name,
         batch_id: row.batch_id ?? "",
         wh_location: row.wh_location,
@@ -135,10 +139,21 @@
     setRemoving(inventoryId);
     const supabase = createClient();
 
-    await supabase
-      .from("warehouse_inventory")
-      .update({ status: "Expired" })
-      .eq("inventory_id", inventoryId);
+    // RC-04 (Batch 3): writing status='Expired' directly to warehouse_inventory
+    // is a stock write-off with no audit/provenance. Route through the canonical
+    // warehouse_expire_writeoff RPC, which role-gates, requires a reason, and
+    // records the write-off. Backward-safe: the RPC exists on the current live
+    // backend.
+    const { error } = await supabase.rpc("warehouse_expire_writeoff", {
+      p_wh_inventory_id: inventoryId,
+      p_reason: "Expired stock write-off from field expiry tab",
+      p_caller_id: null,
+    });
+    if (error) {
+      console.error("[Expiry] warehouse_expire_writeoff error:", error);
+      setRemoving(null);
+      return;
+    }
 
     setRows((prev) => prev.filter((r) => r.inventory_id !== inventoryId));
     setRemoving(null);

===== src/app/(field)/field/config/product-mapping/page.tsx =====
--- a/src/app/(field)/field/config/product-mapping/page.tsx	2026-07-18 14:47:02.531566457 +0000
+++ src/app/(field)/field/config/product-mapping/page.tsx	2026-07-18 14:50:32.293570781 +0000
@@ -441,6 +441,11 @@
     setSaveError(null);
     const supabase = createClient();
 
+    // TODO(Batch 5 / RC-04): product_mapping has NO canonical write RPC today
+    // (delete / insert / update / upsert below). These direct writes are LEFT
+    // AS-IS to avoid breaking mapping edits. Rewire every product_mapping write
+    // in this file to the canonical mapping RPC (e.g. set_product_mapping /
+    // upsert_product_mapping) once it lands in Batch 5.
     try {
       for (const line of lines) {
         if (line.toDelete) {
@@ -577,6 +582,8 @@
     const active = (splitDrafts[key] ?? []).filter((s) => !s.toDelete);
     setBulkSaving(true);
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): direct product_mapping delete+insert — no canonical
+    // mapping RPC exists yet. Left as-is; rewire when the RPC lands.
     for (const mid of bulkSelected) {
       await supabase
         .from("product_mapping")
@@ -625,6 +632,8 @@
     setAddError(null);
     const supabase = createClient();
     const machineId = addMachineId || null;
+    // TODO(Batch 5 / RC-04): direct product_mapping upsert — no canonical
+    // mapping RPC exists yet. Left as-is; rewire when the RPC lands.
     const { error } = await supabase.from("product_mapping").upsert(
       addSplits.map((s) => ({
         pod_product_id: addPodId,

===== src/app/(field)/field/config/machines/page.tsx =====
--- a/src/app/(field)/field/config/machines/page.tsx	2026-07-18 14:47:02.534737708 +0000
+++ src/app/(field)/field/config/machines/page.tsx	2026-07-18 14:50:56.569570226 +0000
@@ -599,6 +599,10 @@
     if (!draft) return;
     setMachineSaving((p) => ({ ...p, [id]: true }));
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): no canonical machine-edit RPC covers this full
+    // field set (add_new_machine lacks contact/venue_group/pod_address;
+    // set_machine_warehouse only touches warehouse assignment). Left as-is to
+    // avoid dropping fields; rewire to a canonical update_machine RPC in Batch 5.
     const { error } = await supabase
       .from("machines")
       .update({
@@ -701,6 +705,10 @@
     setAddingMachine(true);
     setAddMachineError(null);
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): the canonical add_new_machine RPC does NOT accept
+    // contact_person/email/phone, venue_group, or pod_address, so routing here
+    // would silently drop those fields (destructive). Left as a direct insert
+    // until add_new_machine is extended to the full field set in Batch 5.
     const { error } = await supabase.from("machines").insert({
       official_name: newMachine.official_name.trim(),
       pod_number: newMachine.pod_number.trim() || null,
@@ -762,6 +770,9 @@
       return;
     }
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): bulk CSV machine import — no bulk canonical machine
+    // insert RPC exists (add_new_machine is single-row and misses fields). Left
+    // as a direct insert; rewire when a bulk canonical importer lands.
     const { error } = await supabase.from("machines").insert(
       toInsert.map((r) => ({
         official_name: r["official_name"],

===== src/app/(app)/admin/machines/page.tsx =====
--- a/src/app/(app)/admin/machines/page.tsx	2026-07-18 14:47:02.537543298 +0000
+++ src/app/(app)/admin/machines/page.tsx	2026-07-18 14:51:10.565569906 +0000
@@ -230,6 +230,10 @@
 
       if (action === "set_active" || action === "set_inactive") {
         const newStatus = action === "set_active" ? "Active" : "Inactive";
+        // TODO(Batch 5 / RC-04): no canonical set_machine_status RPC exists.
+        // Left as a direct update to preserve the bulk activate/deactivate
+        // capability; rewire (fan-out per row like toggle_machine_refill) once
+        // a set_machine_status RPC lands in Batch 5.
         const { error: updateError } = await supabase
           .from("machines")
           .update({ status: newStatus })
@@ -313,6 +317,9 @@
   const handleSave = useCallback(
     async (machineId: string, updates: Partial<Machine>) => {
       const supabase = createClient();
+      // TODO(Batch 5 / RC-04): arbitrary machine-field edit — no canonical
+      // update_machine RPC exists. Left as a direct update to preserve the edit
+      // capability; rewire once Batch 5 provides a field-scoped machine RPC.
       const { error: updateError } = await supabase
         .from("machines")
         .update(updates)

===== src/app/(app)/app/pods/page.tsx =====
--- a/src/app/(app)/app/pods/page.tsx	2026-07-18 14:47:02.540108551 +0000
+++ src/app/(app)/app/pods/page.tsx	2026-07-18 14:51:16.797569763 +0000
@@ -688,6 +688,9 @@
     }
 
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): arbitrary machine-field edit — no canonical
+    // update_machine RPC exists. Left as a direct update to preserve the edit
+    // capability; rewire once Batch 5 provides a field-scoped machine RPC.
     const { error } = await supabase
       .from("machines")
       .update(diff)

===== src/components/config/MachineSetupConfigTab.tsx =====
--- a/src/components/config/MachineSetupConfigTab.tsx	2026-07-18 14:47:02.542664562 +0000
+++ src/components/config/MachineSetupConfigTab.tsx	2026-07-18 14:51:24.121569596 +0000
@@ -269,6 +269,9 @@
     if (!draft) return;
     setSaving((prev) => ({ ...prev, [machineId]: true }));
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): machine payment/hardware setup fields — no
+    // canonical RPC covers these columns. Left as a direct update to preserve
+    // the setup capability; rewire once a canonical machine-setup RPC lands.
     const { error } = await supabase
       .from("machines")
       .update({

===== src/app/(field)/field/packing/[machineId]/page.tsx =====
--- src/app/(field)/field/packing/[machineId]/page.tsx.orig	2026-07-18 14:47:02.545575578 +0000
+++ src/app/(field)/field/packing/[machineId]/page.tsx	2026-07-18 14:51:41.281569203 +0000
@@ -1368,6 +1368,12 @@
             }
           }
           if (deletableIds.length > 0) {
+            // TODO(Batch 5 / RC-04): this hard-deletes stale un-packed extra
+            // slices so the OB-2 trigger can respawn fresh children. The
+            // canonical remove_dispatch_row soft-cancels (sets cancelled=true),
+            // which would collide with prevent_duplicate_unstarted_dispatch on
+            // respawn. Left as a direct delete to avoid breaking the re-pack
+            // flow; needs a canonical clear-slices RPC (Batch 5).
             const { error: delErr } = await supabase
               .from("refill_dispatching")
               .delete()

===== src/app/(field)/field/dispatching/[machineId]/page.tsx =====
--- src/app/(field)/field/dispatching/[machineId]/page.tsx.orig	2026-07-18 14:47:02.550498295 +0000
+++ src/app/(field)/field/dispatching/[machineId]/page.tsx	2026-07-18 14:51:35.445569337 +0000
@@ -531,6 +531,12 @@
   async function handleRemoveExtraReturn(dispatchId: string) {
     if (!confirm("Remove this driver-added variant from the dispatch?")) return;
     const supabase = createClient();
+    // TODO(Batch 5 / RC-04): this runs in the DRIVER (field_staff) context and
+    // deletes a driver-added dispatch row. remove_dispatch_row exists but is
+    // role-gated to warehouse/operator_admin ("not allowed for driver"), and
+    // cancel_dispatch_line's driver-safety is unverified. Left as a direct
+    // delete to avoid breaking the driver flow; rewire to a driver-safe
+    // canonical cancel/remove RPC in Batch 5.
     const { error } = await supabase
       .from("refill_dispatching")
       .delete()

```
