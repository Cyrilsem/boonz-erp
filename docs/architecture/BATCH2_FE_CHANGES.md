# Batch 2 — Front-end changes (RC-02)

STAX implementation of the Batch 2 FE work for PRD-100: mount the structured
field-capture flow and convert the field inventory inline qty box from a bare
absolute overwrite into a disposition flow. Repo snapshot:
`/home/claude/boonz/boonz-erp` (Next.js 16 App Router, `src/`).

Live-DB signatures verified READ-ONLY against project `eizcexopcuoycuosittm`
on 2026-07-18:

```
record_actual_refill(p_machine_name text, p_plan_date date, p_lines jsonb,
                     p_source text DEFAULT 'cs', p_actor uuid DEFAULT NULL,
                     p_reason text DEFAULT NULL, p_dry_run boolean DEFAULT true)
  RETURNS jsonb  -- {status: dry_run_ok|applied|failed, event_id, machine, plan_date, lines, [failed_at_line, error]}

warehouse_expire_writeoff(p_wh_inventory_id uuid, p_reason text, p_caller_id uuid)
  RETURNS jsonb  -- {status: written_off|already_done, ...}; reason >= 10 chars ENFORCED server-side;
                 -- zeroes warehouse_stock + consumer_stock, audit-logs, inactivation stays propose-then-confirm

attempt_inventory_correction(p_session_id uuid, p_wh_inventory_id uuid,
                             p_new_warehouse_stock numeric, p_reason text,
                             p_client_correlation_id uuid, p_attempted_by uuid) RETURNS jsonb
```

`record_actual_refill` line shape (from live fn body): `{action, boonz_product_id,
shelf_code, qty, set_mode('delta'|'set'), expiration_date, warehouse_id,
partner_machine, notes}`. WAREHOUSE decrement happens ONLY when `warehouse_id`
is present on the line — that is the hook used for on-spot sourcing.

## Files changed

| # | File | Change |
|---|------|--------|
| 1 | `src/components/field/FieldCapturePanel.tsx` | NEW (moved + refactored from `src/app/(app)/refill/FieldCapturePanel.tsx`) |
| 2 | `src/app/(app)/refill/FieldCapturePanel.tsx` | **DELETED** (dead code — imported nowhere; moved to #1. `git mv` + edit) |
| 3 | `src/app/(field)/field/capture/page.tsx` | NEW route `/field/capture` mounting the panel |
| 4 | `src/app/(field)/field/page.tsx` | +2 nav cards ("+ Capture Manual Refill") in WarehouseHome and OperatorAdminHome |
| 5 | `src/app/(field)/field/inventory/page.tsx` | Inline qty box converted to disposition flow |

CS hard rules honored: the inline box is CONVERTED (not deleted) in the same
deploy that mounts the capture flow; nothing destructive; empty shelves stay
fillable via the "Bought on the spot" line flag (pod-only placement, no
phantom WH decrement).

---

## 1+2. FieldCapturePanel — mounted and re-pointed at `record_actual_refill`

**What**: the complete-but-unmounted component (PRD-036/PRD-075 work) moved
from `src/app/(app)/refill/` (where nothing imported it) to
`src/components/field/` (the field-app component convention), and its submit
refactored from legacy `log_manual_refill` to `record_actual_refill` with a
dry-run preview gate. A code comment marks `log_manual_refill` as LEGACY.

**Kept from the original UX**: machine + source-WH pickers, multi-line rows
(product / shelf / qty / expiry), machine-scoped product list with
fill-to-cap qty defaults (PRD-075 WS-B), the unlogged-corrections amber panel
(driver_feedback.resolved=false), offline-tolerant submit (typed lines never
lost).

**New behavior**:
- Submit is a two-step gate: **Preview capture** → RPC with `p_dry_run: true`
  (server validates machine, shelves, products; writes only a `refill_events`
  header with status `dry_run`, applies nothing) → blue preview box lists each
  line ("12 × KitKat → shelf A1 (from WH_CENTRAL) · exp 2026-08-01") →
  **Confirm & apply** → same exact payload with `p_dry_run: false`. Any edit
  to machine/WH/rows clears the preview and forces a re-preview.
- `new_purchase` checkbox renamed to **"Bought on the spot"**: those lines are
  sent WITHOUT `warehouse_id`, so the pod gets the stock and the warehouse is
  untouched (accrual — stock never entered the WH). Expiry is required on
  those lines so the pod batch is honest. Normal lines carry the selected
  `warehouse_id` and decrement WH stock server-side.
- Source WH is only required if at least one line is warehouse-sourced.
- New optional `prefill` prop (`boonz_product_id`, `qty`, `expiration_date`,
  `warehouse_id`) used by the deep link from the inventory disposition flow; a
  prefilled product stays visible even when the machine-scope filter would
  hide it.

**RPC call (greppable literal)**:
```ts
supabase.rpc("record_actual_refill", {
  p_machine_name: machineName,      // machines.official_name
  p_plan_date: getDubaiDate(),
  p_lines: lines,                   // [{action:'refill', boonz_product_id, shelf_code, qty,
                                    //   set_mode:'delta', expiration_date, warehouse_id|null,
                                    //   notes:'on_spot_purchase'|null}]
  p_source: "field_capture",
  p_actor: user?.id ?? null,        // auth.getUser(); role-gated server-side
  p_reason: "field_capture",
  p_dry_run: dryRun,                // true first, false on confirm
});
```

## 3. `/field/capture` route (new)

Dedicated route (a tab/route beats cramming the already-1900-line inventory
page). Client page, `useSearchParams` wrapped in `<Suspense>` (same pattern as
`field/pod-inventory/page.tsx`), `FieldHeader` gives the standard "← Back"
(falls through to `/field` home). Accepts deep-link params
`?product=&warehouse=&qty=&expiry=` and passes them as the panel prefill.

## 4. Field home nav (`src/app/(field)/field/page.tsx`)

"+ Capture Manual Refill" dashed-card link (identical style to "+ New Purchase
Order") added to the **Daily Refills** section of both `WarehouseHome` and
`OperatorAdminHome`. Driver home untouched (drivers use trips/dispatching
flows — Batch 3 territory).

## 5. Inventory inline qty box → disposition flow

**What**: `saveInlineQty` (the ~line-1006 handler behind the 2,027+ blind
absolute overwrites since 05-25) no longer writes on blur. All prior guards
kept (row/warehouse check, Phase G P1 session + role gate with
`alertNoSession()`). Two changes:

1. **No-op guard**: blur with an unchanged value now returns without any RPC
   (previously every blur fired `attempt_inventory_correction` even when
   nothing changed — a large chunk of the 2,027 edits was blur noise).
2. **Disposition chooser** (bottom-sheet modal on mobile, centered on
   desktop) opens when the value actually changed, showing product,
   `old → new (±delta)`, expiry. **No default — the user must choose**:

   - **(a) Count correction** — reason input (autofocused), min 10 chars
     enforced client-side; calls the existing wrapper
     `attemptCorrection` → `attempt_inventory_correction` with
     `reason: "inline_qty_edit: <operator text>"` (keeps the greppable tag;
     backend M1/M2 stamps honest `manual_adjust` provenance).
     **Keyboard path for the ~20/day user: type qty → Tab/blur → type reason →
     Enter. One extra input vs before.** Esc cancels and reverts the box.
   - **(b) Refill to machine** (shown only when qty went DOWN) — writes
     nothing here; reverts the inline value (the capture flow does the WH
     decrement itself, so no double-count) and `router.push`es
     `/field/capture?product=<boonz_product_id>&warehouse=<warehouse_id>&qty=<delta>&expiry=<expiration_date>`.
   - **(c) Write-off** (shown only when qty went DOWN) — reason min 10 chars.
     - new qty **= 0** → `supabase.rpc("warehouse_expire_writeoff", {
       p_wh_inventory_id, p_reason: "write-off: <text>", p_caller_id: user.id })`
       (RPC exists live — verified). Treats `written_off` and `already_done`
       as success.
     - new qty **> 0** (partial) → **GAP**: no partial write-off RPC exists;
       routed through `attemptCorrection` with mandatory
       `reason: "write-off: <text>"` prefix so provenance is honest and the
       cases are greppable for a future `warehouse_partial_writeoff` RPC.
       Button labeled "Write off (partial — logged as correction)".

   On success/failure the existing ✓/✗ per-row feedback ticks are reused; on
   failure or cancel the inline value reverts to the server value.

**Untouched (per instructions)**: `DailyDispatchingTab` "Mark All", driver
trips direct writes (Batch 3), the bulk "Inventory Control" mode
(`completeControl` — that is the deliberate counted-session flow, reason
`inventory_control`), and inline *location* edits (metadata-only writer).

---

## UX flow summary for CS

- Warehouse user opens Inventory, starts an Inventory Control session as
  today, taps a qty box, types the new number, blurs. Instead of silently
  saving, a small sheet asks what the change IS. Recount → type why (10+
  chars), hit Enter, done — two seconds. Stock that actually went into a
  machine → one tap lands them in Refill Capture with product/qty/WH/expiry
  already filled; they pick the machine + shelf, hit Preview, then Confirm —
  and the pod, the warehouse, refill_plan_output AND the refill_events ledger
  all move together. Expired/damaged → write-off with a reason, audit-logged,
  and the inactivation still goes through the manager's propose-then-confirm.
- Empty shelf, stock bought on the spot: in Refill Capture tick "Bought on
  the spot" on the line, set the expiry — the machine gets filled, the
  warehouse is NOT debited, and the ledger says exactly that. No more
  Google-Doc entries or blind stock edits.

## Deploy notes (ORDER MATTERS)

1. **Backend M1/M2 must be applied FIRST** (parallel backend migration
   batch): M2 fixes `record_actual_refill` (same signature — FE wiring here
   matches the live/target signature) and M1 gives
   `attempt_inventory_correction` honest `manual_adjust` provenance. The FE
   calls will *run* against today's functions but the provenance/ledger
   guarantees only hold after M1/M2.
2. Then Vercel deploy of this FE change set (one deploy — the inline box
   conversion and the capture mount ship together per CS hard rule 1).
3. No env var, schema, or RLS changes needed FE-side. No new packages.

## Reviewer checklist (run in a full checkout)

The snapshot has no `node_modules` and the sandbox npm registry blocks scoped
packages, so full verification could not run here. What WAS run: a strict
`tsc` pass (TypeScript 6.0.3) over the four changed/new files + all their
local project imports, with faithful ambient stubs for `react`,
`next/navigation`, `next/link`, `@supabase/ssr`, `@supabase/supabase-js` —
**0 errors** (the only findings were pre-existing unused symbols
`formatDate`/`ExpiryBadge`/`groups` in the inventory page, untouched). Every
referenced symbol was grep-verified to exist in the snapshot
(`FieldHeader`, `attemptCorrection`, `correlationId`, `useInventorySession`,
`getDubaiDate`, `createClient`, `formatExpiryBatch`, Suspense pattern).

Must-run before merge:
1. `npx tsc --noEmit` (per CLAUDE.md, after every change)
2. `npm run build` && `npm run lint`
3. Confirm `src/app/(app)/refill/FieldCapturePanel.tsx` is deleted in the
   commit (this is a move; leaving both files is harmless but confusing).
4. Smoke: `/field/capture` renders for warehouse + operator_admin; dry-run
   preview rejects a bad shelf code with the server message; confirm applies
   and the machine's pod stock + WH stock + `refill_events`/`refill_event_lines`
   all move; `?product=...` deep link prefills.
5. Smoke: inventory qty edit → modal; Esc reverts; Enter path saves a
   correction with the typed reason in `inventory_control_attempt`; qty→0 +
   write-off zeroes the row and raises the inactivation proposal.
6. `warehouse` test user: `warehouse@boonz.test / Test1234!` (CLAUDE.md).

---

# Unified diffs

## src/app/(field)/field/page.tsx
```diff
--- /tmp/orig/field-home.tsx	2026-07-18 13:22:53.515823135 +0000
+++ boonz-erp/src/app/(field)/field/page.tsx	2026-07-18 13:24:55.725431632 +0000
@@ -393,6 +393,13 @@
             cardStyle={ratioCardStyle(kpis.dispatchedMachines, n)}
             href="/field/dispatching"
           />
+          {/* RC-02: structured capture of unplanned/on-spot refills */}
+          <Link
+            href="/field/capture"
+            className="col-span-2 flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
+          >
+            + Capture Manual Refill
+          </Link>
         </div>
       </SectionCard>
 
@@ -808,6 +815,13 @@
             cardStyle={ratioCardStyle(kpis.dispatchedMachines, n)}
             href="/field/dispatching"
           />
+          {/* RC-02: structured capture of unplanned/on-spot refills */}
+          <Link
+            href="/field/capture"
+            className="col-span-2 flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
+          >
+            + Capture Manual Refill
+          </Link>
         </div>
       </SectionCard>
 
```

## src/app/(field)/field/inventory/page.tsx
```diff
--- /tmp/orig/inventory-page.tsx	2026-07-18 13:22:53.514172536 +0000
+++ boonz-erp/src/app/(field)/field/inventory/page.tsx	2026-07-18 13:26:00.701435495 +0000
@@ -10,6 +10,7 @@
   SetStateAction,
 } from "react";
 import Link from "next/link";
+import { useRouter } from "next/navigation";
 import { createClient } from "@/lib/supabase/client";
 import { getDubaiDate } from "@/lib/utils/date";
 import { adjustWarehouseLineMetadata } from "@/lib/inventory/adjust-warehouse-line";
@@ -142,6 +143,19 @@
   location?: "saved" | "error";
 };
 
+// RC-02 (Batch 2, PRD-100): a WH qty edit is no longer a bare absolute
+// overwrite. The user must pick a disposition: count correction (with reason),
+// refill to machine (deep-links the capture flow), or write-off.
+interface DispositionState {
+  id: string; // wh_inventory_id
+  oldQty: number;
+  newQty: number;
+  productId: string;
+  productName: string;
+  warehouseId: string;
+  expirationDate: string | null;
+}
+
 const expiryFilters: { label: string; value: ExpiryFilter }[] = [
   { label: "All", value: "all" },
   { label: "Expired", value: "expired" },
@@ -488,6 +502,13 @@
     Record<string, SaveFeedback>
   >({});
 
+  // RC-02: disposition chooser state for inline qty edits.
+  const router = useRouter();
+  const [disposition, setDisposition] = useState<DispositionState | null>(null);
+  const [dispositionReason, setDispositionReason] = useState("");
+  const [dispositionSaving, setDispositionSaving] = useState(false);
+  const [dispositionError, setDispositionError] = useState<string | null>(null);
+
   // Pending reviews
   const [userRole, setUserRole] = useState<string | null>(null);
   // PRD-001: track manual tab/dropdown change so the role-aware default below
@@ -974,6 +995,15 @@
     }, 1500);
   }
 
+  // RC-02 (Batch 2, PRD-100): the inline qty box no longer performs a bare
+  // absolute overwrite on blur. It now opens a disposition chooser — the
+  // warehouse user must say WHY the number changed: (a) count correction with
+  // a reason (>= 10 chars, still via attempt_inventory_correction, which now
+  // stamps honest manual_adjust provenance after backend M1/M2), (b) refill to
+  // machine (deep-links /field/capture prefilled -> record_actual_refill), or
+  // (c) write-off (warehouse_expire_writeoff for a full batch; partial
+  // write-offs go through count-correction with a mandatory 'write-off:'
+  // prefix — there is no partial write-off RPC yet).
   async function saveInlineQty(id: string, qty: number) {
     const safeQty = Math.max(0, qty);
     const row = rows.find((r) => r.wh_inventory_id === id);
@@ -985,6 +1015,9 @@
       clearFeedbackField(id, "qty");
       return;
     }
+    // Unchanged value -> no write, no modal (previously every blur fired an
+    // attempt_inventory_correction even when nothing changed).
+    if (safeQty === row.warehouse_stock) return;
     // Phase G P1: stock writes must flow through attempt_inventory_correction
     // so the session captures the attempt (success or failure).
     if (!canEdit || !session) {
@@ -998,16 +1031,33 @@
       alertNoSession();
       return;
     }
-    const supabase = createClient();
-    const result = await attemptCorrection(supabase, {
-      sessionId: session.session_id,
-      whInventoryId: id,
-      newWarehouseStock: safeQty,
-      reason: "inline_qty_edit",
-      correlationId: correlationId(),
+    setDispositionReason("");
+    setDispositionError(null);
+    setDisposition({
+      id,
+      oldQty: row.warehouse_stock,
+      newQty: safeQty,
+      productId: row.boonz_product_id,
+      productName: row.boonz_product_name,
+      warehouseId: row.warehouse_id,
+      expirationDate: row.expiration_date,
     });
+  }
+
+  /** Close the chooser without writing; revert the inline value. */
+  function cancelDisposition() {
+    if (!disposition) return;
+    setInlineQtys((prev) => ({
+      ...prev,
+      [disposition.id]: disposition.oldQty,
+    }));
+    setDisposition(null);
+  }
 
-    const ok = result.result === "success";
+  /** Shared post-write bookkeeping for the disposition paths. */
+  function finishDisposition(ok: boolean, appliedQty: number) {
+    if (!disposition) return;
+    const { id, oldQty } = disposition;
     setSaveFeedback((prev) => ({
       ...prev,
       [id]: { ...prev[id], qty: ok ? "saved" : "error" },
@@ -1015,11 +1065,103 @@
     if (ok) {
       setRows((prev) =>
         prev.map((r) =>
-          r.wh_inventory_id === id ? { ...r, warehouse_stock: safeQty } : r,
+          r.wh_inventory_id === id ? { ...r, warehouse_stock: appliedQty } : r,
         ),
       );
+    } else {
+      setInlineQtys((prev) => ({ ...prev, [id]: oldQty }));
     }
     clearFeedbackField(id, "qty");
+    setDispositionSaving(false);
+    setDisposition(null);
+  }
+
+  /** Disposition (a): count correction — reason required, >= 10 chars. */
+  async function applyCountCorrection() {
+    if (!disposition || !session) return;
+    const reason = dispositionReason.trim();
+    if (reason.length < 10) {
+      setDispositionError(
+        `Count correction needs a reason of at least 10 characters (got ${reason.length}).`,
+      );
+      return;
+    }
+    setDispositionSaving(true);
+    const supabase = createClient();
+    const result = await attemptCorrection(supabase, {
+      sessionId: session.session_id,
+      whInventoryId: disposition.id,
+      newWarehouseStock: disposition.newQty,
+      reason: `inline_qty_edit: ${reason}`,
+      correlationId: correlationId(),
+    });
+    finishDisposition(result.result === "success", disposition.newQty);
+  }
+
+  /** Disposition (c): write-off (expired/damaged). Full batch (new qty 0)
+   *  routes through warehouse_expire_writeoff (zeroes the row, audit-logged,
+   *  inactivation stays propose-then-confirm). Partial write-offs fall back to
+   *  attempt_inventory_correction with a mandatory 'write-off:' reason prefix
+   *  — no partial write-off RPC exists yet (gap noted in FE_CHANGES). */
+  async function applyWriteOff() {
+    if (!disposition || !session) return;
+    const reason = dispositionReason.trim();
+    if (reason.length < 10) {
+      setDispositionError(
+        `Write-off needs a reason of at least 10 characters (got ${reason.length}).`,
+      );
+      return;
+    }
+    setDispositionSaving(true);
+    const supabase = createClient();
+    if (disposition.newQty === 0) {
+      const {
+        data: { user },
+      } = await supabase.auth.getUser();
+      // Live signature (verified): warehouse_expire_writeoff(
+      //   p_wh_inventory_id uuid, p_reason text, p_caller_id uuid) -> jsonb
+      const { data, error } = await supabase.rpc("warehouse_expire_writeoff", {
+        p_wh_inventory_id: disposition.id,
+        p_reason: `write-off: ${reason}`,
+        p_caller_id: user?.id ?? null,
+      });
+      const status = (data as { status?: string } | null)?.status;
+      const ok =
+        !error && (status === "written_off" || status === "already_done");
+      if (!ok && error) setDispositionError(error.message);
+      finishDisposition(ok, 0);
+      return;
+    }
+    const result = await attemptCorrection(supabase, {
+      sessionId: session.session_id,
+      whInventoryId: disposition.id,
+      newWarehouseStock: disposition.newQty,
+      reason: `write-off: ${reason}`,
+      correlationId: correlationId(),
+    });
+    finishDisposition(result.result === "success", disposition.newQty);
+  }
+
+  /** Disposition (b): the qty drop was really a refill — nothing is written
+   *  here. Revert the inline value (record_actual_refill will do the WH
+   *  decrement itself) and deep-link the capture flow prefilled. */
+  function goToRefillCapture() {
+    if (!disposition) return;
+    const delta = disposition.oldQty - disposition.newQty;
+    setInlineQtys((prev) => ({
+      ...prev,
+      [disposition.id]: disposition.oldQty,
+    }));
+    const params = new URLSearchParams({
+      product: disposition.productId,
+      warehouse: disposition.warehouseId,
+      qty: String(delta),
+    });
+    if (disposition.expirationDate) {
+      params.set("expiry", disposition.expirationDate);
+    }
+    setDisposition(null);
+    router.push(`/field/capture?${params.toString()}`);
   }
 
   async function saveInlineLocation(id: string, location: string) {
@@ -1841,6 +1983,92 @@
         </div>
       </div>
 
+      {/* RC-02: disposition chooser for inline qty edits. No default — the
+          user must pick what the change IS. Keyboard path for the common case
+          (count correction): type qty, blur, type reason, Enter. Esc cancels. */}
+      {disposition && (
+        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-4 sm:items-center">
+          <div className="w-full max-w-md rounded-2xl bg-white p-4 shadow-xl dark:bg-neutral-900">
+            <p className="text-sm font-bold">{disposition.productName}</p>
+            <p className="mt-0.5 text-xs text-neutral-500">
+              {disposition.oldQty} → {disposition.newQty} (
+              {disposition.newQty - disposition.oldQty > 0 ? "+" : ""}
+              {disposition.newQty - disposition.oldQty} units)
+              {disposition.expirationDate
+                ? ` · exp ${formatExpiryBatch(disposition.expirationDate)}`
+                : ""}
+            </p>
+            <p className="mt-2 text-xs text-neutral-600 dark:text-neutral-400">
+              What is this change? Nothing is saved until you choose.
+            </p>
+
+            <input
+              type="text"
+              autoFocus
+              value={dispositionReason}
+              onChange={(e) => {
+                setDispositionReason(e.target.value);
+                setDispositionError(null);
+              }}
+              onKeyDown={(e) => {
+                if (e.key === "Enter" && !dispositionSaving) {
+                  void applyCountCorrection();
+                } else if (e.key === "Escape") {
+                  cancelDisposition();
+                }
+              }}
+              placeholder="Reason (min 10 chars) — required for correction / write-off"
+              className="mt-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-950"
+            />
+            {dispositionError && (
+              <p className="mt-1 text-xs text-red-600 dark:text-red-400">
+                {dispositionError}
+              </p>
+            )}
+
+            <div className="mt-3 flex flex-col gap-2">
+              <button
+                onClick={() => void applyCountCorrection()}
+                disabled={dispositionSaving}
+                className="w-full rounded-lg bg-blue-600 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-40"
+              >
+                {dispositionSaving
+                  ? "Saving…"
+                  : "✓ Count correction (Enter)"}
+              </button>
+              {disposition.newQty < disposition.oldQty && (
+                <button
+                  onClick={goToRefillCapture}
+                  disabled={dispositionSaving}
+                  className="w-full rounded-lg border border-blue-300 py-2 text-sm font-semibold text-blue-700 hover:bg-blue-50 disabled:opacity-40 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950/30"
+                >
+                  → Refill to machine (
+                  {disposition.oldQty - disposition.newQty} units)
+                </button>
+              )}
+              {disposition.newQty < disposition.oldQty && (
+                <button
+                  onClick={() => void applyWriteOff()}
+                  disabled={dispositionSaving}
+                  className="w-full rounded-lg border border-red-300 py-2 text-sm font-semibold text-red-600 hover:bg-red-50 disabled:opacity-40 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/30"
+                >
+                  {disposition.newQty === 0
+                    ? "🗑 Write off entire batch (expired/damaged)"
+                    : "🗑 Write off (partial — logged as correction)"}
+                </button>
+              )}
+              <button
+                onClick={cancelDisposition}
+                disabled={dispositionSaving}
+                className="w-full rounded-lg bg-neutral-100 py-2 text-sm font-medium text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-300 dark:hover:bg-neutral-700"
+              >
+                Cancel (Esc)
+              </button>
+            </div>
+          </div>
+        </div>
+      )}
+
       {/* Review toast */}
       {reviewToast && (
         <div className="fixed bottom-24 left-4 right-4 z-50 rounded-xl bg-green-100 px-4 py-3 text-center text-sm font-medium text-green-800 shadow-lg dark:bg-green-900 dark:text-green-200">
```

## src/components/field/FieldCapturePanel.tsx (moved from src/app/(app)/refill/FieldCapturePanel.tsx — diff vs the old file)
```diff
--- /tmp/orig/FieldCapturePanel.tsx	2026-07-18 13:22:53.517613084 +0000
+++ boonz-erp/src/components/field/FieldCapturePanel.tsx	2026-07-18 13:24:02.353428460 +0000
@@ -1,12 +1,27 @@
 "use client";
 
-// PRD-036 Phase B: field-time batch + expiry capture.
-// Captures qty + expiry + new-purchase flag per line and submits through the
-// canonical writer log_manual_refill (Rule S1: no direct table writes; S2: the
-// rpc() call site is a greppable literal). For new_purchase=true the writer
-// creates a WH receipt batch with the captured expiry then places to the pod;
-// for replacement/existing-stock (new_purchase=false) it FEFO-decrements WH then
-// places. Replaces the "Error in the Data: log it on paper" backlog.
+// PRD-036 Phase B / PRD-100 RC-02: field-time batch + expiry capture.
+// Captures qty + expiry + on-the-spot-purchase flag per line and submits
+// through the canonical writer record_actual_refill (Rule S1: no direct table
+// writes; S2: the rpc() call site is a greppable literal).
+//
+// RC-02 (Batch 2): submit was refactored from log_manual_refill to
+// record_actual_refill. log_manual_refill is LEGACY — it pre-dates the
+// refill_events / refill_event_lines ledger and does not produce a dry-run
+// preview. record_actual_refill writes the pod + warehouse + refill_plan_output
+// log AND the refill_events ledger atomically, with p_dry_run=true validation
+// first (nothing applied) and p_dry_run=false on operator confirm.
+//
+// Sourcing semantics (CS hard rule 3 — empty shelves must always be fillable):
+// - normal line  -> action 'refill' with warehouse_id: FEFO-style WH decrement
+//   then pod placement.
+// - "Bought on the spot" line -> action 'refill' WITHOUT warehouse_id: pod-only
+//   placement (stock never entered the warehouse), expiry required so the pod
+//   batch is honest. No phantom WH decrement.
+//
+// This component was previously dead code under src/app/(app)/refill/ —
+// it is now mounted at /field/capture (RC-02) and deep-linked from the
+// field inventory disposition flow.
 
 import { useState, useEffect, useCallback } from "react";
 import { createClient } from "@/lib/supabase/client";
@@ -23,6 +38,36 @@
   new_purchase: boolean;
 };
 
+/** Prefill passed by the inventory disposition flow (deep link). */
+export interface CapturePrefill {
+  boonz_product_id?: string;
+  qty?: string;
+  expiration_date?: string;
+  warehouse_id?: string;
+}
+
+// record_actual_refill p_lines element (live signature verified 2026-07-18).
+type RefillLine = {
+  action: "refill";
+  boonz_product_id: string;
+  shelf_code: string;
+  qty: number;
+  set_mode: "delta";
+  expiration_date: string | null;
+  warehouse_id: string | null;
+  notes: string | null;
+};
+
+type RecordActualRefillResponse = {
+  status?: "dry_run_ok" | "applied" | "failed";
+  event_id?: string;
+  machine?: string;
+  plan_date?: string;
+  lines?: number;
+  failed_at_line?: number;
+  error?: string;
+} | null;
+
 // PRD-036 Phase B step 3: unresolved field corrections (driver_feedback.resolved=false).
 type UnloggedCorrection = {
   feedback_id: string;
@@ -36,19 +81,19 @@
 };
 
 let rowSeq = 0;
-function blankRow(): CaptureRow {
+function blankRow(prefill?: CapturePrefill): CaptureRow {
   rowSeq += 1;
   return {
     key: `r${rowSeq}`,
-    boonz_product_id: "",
+    boonz_product_id: prefill?.boonz_product_id ?? "",
     shelf_code: "",
-    qty: "",
-    expiration_date: "",
+    qty: prefill?.qty ?? "",
+    expiration_date: prefill?.expiration_date ?? "",
     new_purchase: false,
   };
 }
 
-export function FieldCapturePanel() {
+export function FieldCapturePanel({ prefill }: { prefill?: CapturePrefill }) {
   const planDate = getDubaiDate();
 
   const [machines, setMachines] = useState<Opt[]>([]);
@@ -63,12 +108,18 @@
     {},
   );
   const [machineName, setMachineName] = useState("");
-  const [warehouseId, setWarehouseId] = useState("");
-  const [rows, setRows] = useState<CaptureRow[]>([blankRow()]);
+  const [warehouseId, setWarehouseId] = useState(prefill?.warehouse_id ?? "");
+  const [rows, setRows] = useState<CaptureRow[]>([blankRow(prefill)]);
   const [submitting, setSubmitting] = useState(false);
   const [result, setResult] = useState<string | null>(null);
   const [error, setError] = useState<string | null>(null);
   const [unlogged, setUnlogged] = useState<UnloggedCorrection[]>([]);
+  // RC-02: dry-run preview gate. Holds the exact payload that was validated so
+  // Confirm applies precisely what the operator previewed. Any edit clears it.
+  const [preview, setPreview] = useState<{
+    lines: RefillLine[];
+    lineCount: number;
+  } | null>(null);
 
   useEffect(() => {
     let cancelled = false;
@@ -128,6 +179,7 @@
   }, []);
 
   const updateRow = useCallback((key: string, patch: Partial<CaptureRow>) => {
+    setPreview(null); // edited after preview -> must re-preview
     setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)));
   }, []);
 
@@ -198,67 +250,104 @@
     };
   }, [machineName, machines]);
 
-  async function submit() {
+  function buildLines(): RefillLine[] | string {
+    if (!machineName) return "Pick a machine";
+    const complete = rows.filter(
+      (r) => r.boonz_product_id && r.shelf_code && Number(r.qty) > 0,
+    );
+    if (complete.length === 0) return "Add at least one complete line";
+    const needsWh = complete.some((r) => !r.new_purchase);
+    if (needsWh && !warehouseId)
+      return "Pick a source warehouse (or mark lines as bought on the spot)";
+    const bad = complete.find((l) => l.new_purchase && !l.expiration_date);
+    if (bad)
+      return "An on-the-spot purchase line needs an expiry date (it creates the pod batch)";
+    return complete.map((r) => ({
+      action: "refill" as const,
+      boonz_product_id: r.boonz_product_id,
+      shelf_code: r.shelf_code.trim(),
+      qty: Number(r.qty),
+      set_mode: "delta" as const,
+      expiration_date: r.expiration_date || null,
+      // CS hard rule 3: on-the-spot sourcing never decrements the warehouse —
+      // record_actual_refill only touches WH stock when warehouse_id is set.
+      warehouse_id: r.new_purchase ? null : warehouseId,
+      notes: r.new_purchase ? "on_spot_purchase" : null,
+    }));
+  }
+
+  async function callRecordActualRefill(lines: RefillLine[], dryRun: boolean) {
+    const supabase = createClient();
+    const {
+      data: { user },
+    } = await supabase.auth.getUser();
+    // Live signature (verified): record_actual_refill(p_machine_name text,
+    // p_plan_date date, p_lines jsonb, p_source text, p_actor uuid,
+    // p_reason text, p_dry_run boolean) -> jsonb
+    return supabase.rpc("record_actual_refill", {
+      p_machine_name: machineName,
+      p_plan_date: planDate,
+      p_lines: lines,
+      p_source: "field_capture",
+      p_actor: user?.id ?? null,
+      p_reason: "field_capture",
+      p_dry_run: dryRun,
+    });
+  }
+
+  async function submit(dryRun: boolean) {
     setError(null);
     setResult(null);
-    if (!machineName) return setError("Pick a machine");
-    if (!warehouseId) return setError("Pick a source warehouse");
-    const lines = rows
-      .filter((r) => r.boonz_product_id && r.shelf_code && Number(r.qty) > 0)
-      .map((r) => ({
-        boonz_product_id: r.boonz_product_id,
-        shelf_code: r.shelf_code.trim(),
-        qty: Number(r.qty),
-        expiration_date: r.expiration_date || null,
-        new_purchase: r.new_purchase,
-      }));
-    if (lines.length === 0) return setError("Add at least one complete line");
-    const bad = lines.find((l) => l.new_purchase && !l.expiration_date);
-    if (bad)
-      return setError(
-        "A new-purchase line needs an expiry date (it creates the WH batch)",
-      );
+    const linesOrError = dryRun ? buildLines() : (preview?.lines ?? null);
+    if (typeof linesOrError === "string") return setError(linesOrError);
+    if (!linesOrError) return setError("Preview first, then confirm.");
+    const lines = linesOrError;
 
     // PRD-075 WS-B: offline-tolerant submit - never lose typed lines. Rows are
     // only cleared on confirmed success; network failures keep state + prompt retry.
     if (typeof navigator !== "undefined" && !navigator.onLine) {
       return setError(
-        "You look offline — your lines are kept. Reconnect and press Submit again.",
+        "You look offline — your lines are kept. Reconnect and try again.",
       );
     }
     setSubmitting(true);
-    const supabase = createClient();
-    let data: unknown = null;
+    let data: RecordActualRefillResponse = null;
     let rpcErr: { message: string } | null = null;
     try {
-      const res = await supabase.rpc("log_manual_refill", {
-        p_machine_name: machineName,
-        p_source_warehouse_id: warehouseId,
-        p_refill_date: planDate,
-        p_lines: lines,
-        p_reason: "field_capture",
-      });
-      data = res.data;
+      const res = await callRecordActualRefill(lines, dryRun);
+      data = res.data as RecordActualRefillResponse;
       rpcErr = res.error;
     } catch {
       rpcErr = {
         message:
-          "Network error — your lines are kept. Reconnect and press Submit again.",
+          "Network error — your lines are kept. Reconnect and try again.",
       };
     }
     setSubmitting(false);
     if (rpcErr) {
+      setPreview(null);
       setError(rpcErr.message);
       return;
     }
-    const r = data as {
-      lines_processed?: number;
-      total_units_to_pod?: number;
-      shortfall_warning?: string | null;
-    } | null;
+    if (data?.status === "failed") {
+      setPreview(null);
+      setError(
+        `Rejected${data.failed_at_line ? ` at line ${data.failed_at_line}` : ""}: ${
+          data.error ?? "unknown error"
+        }`,
+      );
+      return;
+    }
+    if (dryRun) {
+      // dry_run_ok: nothing was applied — show the gate.
+      setPreview({ lines, lineCount: data?.lines ?? lines.length });
+      return;
+    }
+    setPreview(null);
     setResult(
-      `Captured ${r?.lines_processed ?? 0} line(s), ${r?.total_units_to_pod ?? 0} units to pod.` +
-        (r?.shortfall_warning ? ` ⚠ ${r.shortfall_warning}` : ""),
+      `Applied ${data?.lines ?? lines.length} line(s) to ${machineName} (event ${
+        data?.event_id ?? "?"
+      }).`,
     );
     setRows([blankRow()]);
   }
@@ -269,9 +358,10 @@
   return (
     <div className="space-y-4">
       <p className="text-sm text-gray-600">
-        Field batch capture ({planDate}). Records a physical placement (new
-        purchase, replacement, or partial) straight into the warehouse + pod via
-        the canonical path. No more paper backlog.
+        Field refill capture ({planDate}). Records a physical placement
+        (warehouse-sourced or bought on the spot) straight into the pod +
+        warehouse + refill ledger via the canonical path. Preview validates
+        everything first; nothing is written until you confirm.
       </p>
 
       {error && (
@@ -314,7 +404,10 @@
           <span className="mr-2 text-gray-600">Machine</span>
           <select
             value={machineName}
-            onChange={(e) => setMachineName(e.target.value)}
+            onChange={(e) => {
+              setPreview(null);
+              setMachineName(e.target.value);
+            }}
             className={inputCls}
           >
             <option value="">— select —</option>
@@ -329,7 +422,10 @@
           <span className="mr-2 text-gray-600">Source WH</span>
           <select
             value={warehouseId}
-            onChange={(e) => setWarehouseId(e.target.value)}
+            onChange={(e) => {
+              setPreview(null);
+              setWarehouseId(e.target.value);
+            }}
             className={inputCls}
           >
             <option value="">— select —</option>
@@ -365,7 +461,12 @@
             >
               <option value="">— product —</option>
               {(scopedProductIds.size > 0
-                ? products.filter((p) => scopedProductIds.has(p.id))
+                ? // keep a deep-linked/selected product visible even when the
+                  // machine scope would filter it out
+                  products.filter(
+                    (p) =>
+                      scopedProductIds.has(p.id) || p.id === r.boonz_product_id,
+                  )
                 : products
               ).map((p) => (
                 <option key={p.id} value={p.id}>
@@ -405,14 +506,15 @@
                   updateRow(r.key, { new_purchase: e.target.checked })
                 }
               />
-              New purchase
+              Bought on the spot
             </label>
             <button
-              onClick={() =>
+              onClick={() => {
+                setPreview(null);
                 setRows((rs) =>
                   rs.length > 1 ? rs.filter((x) => x.key !== r.key) : rs,
-                )
-              }
+                );
+              }}
               className="ml-auto rounded border border-gray-300 px-2 py-1 text-xs"
             >
               ✕
@@ -421,20 +523,59 @@
         ))}
       </div>
 
+      {preview && (
+        <div className="rounded-lg border border-blue-300 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-800 dark:bg-blue-950/30 dark:text-blue-200">
+          <p className="font-semibold">
+            Preview OK — {preview.lineCount} line(s) to {machineName}. Nothing
+            written yet.
+          </p>
+          <ul className="mt-1 space-y-0.5 text-xs">
+            {preview.lines.map((l, i) => (
+              <li key={i}>
+                {l.qty} ×{" "}
+                {products.find((p) => p.id === l.boonz_product_id)?.name ??
+                  l.boonz_product_id}{" "}
+                → shelf {l.shelf_code}
+                {l.warehouse_id
+                  ? ` (from ${
+                      warehouses.find((w) => w.id === l.warehouse_id)?.name ??
+                      "WH"
+                    })`
+                  : " (bought on the spot — no WH decrement)"}
+                {l.expiration_date ? ` · exp ${l.expiration_date}` : ""}
+              </li>
+            ))}
+          </ul>
+        </div>
+      )}
+
       <div className="flex gap-2">
         <button
-          onClick={() => setRows((rs) => [...rs, blankRow()])}
+          onClick={() => {
+            setPreview(null);
+            setRows((rs) => [...rs, blankRow()]);
+          }}
           className="rounded-lg border border-gray-300 px-3 py-1.5 text-sm"
         >
           + Add line
         </button>
-        <button
-          onClick={submit}
-          disabled={submitting}
-          className="rounded-lg bg-black px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
-        >
-          {submitting ? "Capturing…" : "Capture to WH + pod"}
-        </button>
+        {!preview ? (
+          <button
+            onClick={() => void submit(true)}
+            disabled={submitting}
+            className="rounded-lg bg-black px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
+          >
+            {submitting ? "Checking…" : "Preview capture"}
+          </button>
+        ) : (
+          <button
+            onClick={() => void submit(false)}
+            disabled={submitting}
+            className="rounded-lg bg-green-700 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
+          >
+            {submitting ? "Applying…" : "Confirm & apply"}
+          </button>
+        )}
       </div>
     </div>
   );
```

## src/app/(field)/field/capture/page.tsx (new file)
```diff
--- /dev/null	2026-07-18 09:27:21.992973788 +0000
+++ boonz-erp/src/app/(field)/field/capture/page.tsx	2026-07-18 13:24:11.369428996 +0000
@@ -0,0 +1,54 @@
+"use client";
+
+// RC-02 (Batch 2, PRD-100): dedicated field surface for structured refill
+// capture. Mounts FieldCapturePanel (previously dead code) and wires it to
+// record_actual_refill. Deep-linked from the inventory disposition flow with
+// ?product=&warehouse=&qty=&expiry= so a WH qty edit that is really a refill
+// lands here prefilled instead of being a blind stock overwrite.
+
+import { Suspense } from "react";
+import { useSearchParams } from "next/navigation";
+import { FieldHeader } from "../../components/field-header";
+import {
+  FieldCapturePanel,
+  type CapturePrefill,
+} from "@/components/field/FieldCapturePanel";
+
+// Default export wraps the inner component in <Suspense>. Required by
+// Next.js App Router when useSearchParams() is used in a client component
+// — without it, the build fails the static-render bailout check.
+export default function CapturePage() {
+  return (
+    <Suspense
+      fallback={
+        <>
+          <FieldHeader title="Refill Capture" />
+          <div className="flex items-center justify-center p-8">
+            <p className="text-neutral-500">Loading…</p>
+          </div>
+        </>
+      }
+    >
+      <CapturePageInner />
+    </Suspense>
+  );
+}
+
+function CapturePageInner() {
+  const searchParams = useSearchParams();
+  const prefill: CapturePrefill = {
+    boonz_product_id: searchParams.get("product") ?? undefined,
+    warehouse_id: searchParams.get("warehouse") ?? undefined,
+    qty: searchParams.get("qty") ?? undefined,
+    expiration_date: searchParams.get("expiry") ?? undefined,
+  };
+
+  return (
+    <div className="pb-24">
+      <FieldHeader title="Refill Capture" />
+      <div className="px-4 py-4">
+        <FieldCapturePanel prefill={prefill} />
+      </div>
+    </div>
+  );
+}
```
