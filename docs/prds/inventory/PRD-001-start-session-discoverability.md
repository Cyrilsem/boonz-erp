---
id: PRD-001
title: Inventory edits can't be saved — session-gate is invisible and the two "Inventory Control" buttons collide
status: Done
severity: P1
reported: 2026-05-25
source: CS — Simran (warehouse@boonz.test) unable to save stock edits, 2026-05-25. Initial scope was wrong page; corrected after CS sent the WhatsApp screenshot showing /field/inventory.
routing: [Stax]
protected_entities: []
done_summary:
  commit: afe6a95
  shipped_at: 2026-05-25
  changes:
    - Change 1 — header button on /field/inventory renamed `+ Inventory Control` to `+ Bulk Edit` so it no longer collides with the session-opening `Start Inventory Control` action inside the bar. Tooltip points to the Start button at the top.
    - Change 2 — session bar plus canary wrapper is `position: sticky` under the page header on both /field/inventory (Tailwind `sticky top-[var(--field-header-height,56px)]`) and /app/inventory (inline `style={{position:'sticky',top:0,zIndex:30,...}}` for parity with that page's inline-style pattern).
    - Change 3 — shared `alertNoSession()` helper replaces silent early-returns in `saveInlineQty`, `toggleBatchStatus`, and `completeControl`. Pops `window.alert()` and scroll-snaps the bar back into view via `document.getElementById('start-inventory-session-bar').scrollIntoView`. The anchor id is set on all five render branches of `StartInventorySessionBar`.
    - Change 4 — `handleEnterBulkEdit` re-verifies an open `inventory_control_session` row owned by the current user before flipping `controlMode=true`, killing the localStorage-flicker bypass.
  files:
    - src/app/(field)/field/inventory/page.tsx
    - src/app/(app)/app/inventory/page.tsx
    - src/components/inventory/StartInventorySessionBar.tsx
    - docs/architecture/CHANGELOG.md
  verification:
    tsc: pass
    build: pass
    smoke_test: pending CS verification in production as warehouse@boonz.test (sticky + keyboard behaviour, bulk-edit gated by DB session re-check, three silent paths now alert loudly)
---

# PRD-001 (inventory) — Inventory edits fail silently because the session-gate is invisible

## Problem

The warehouse manager (Simran, `warehouse@boonz.test`, role `warehouse`) cannot save any inventory stock / status / expiry edit on `/field/inventory` (mobile PWA). Every Save click silently rejects and the row "reverts to the original value" on the next refetch.

Database evidence as of 2026-05-25 morning:

- `inventory_control_session` — **0 rows ever** for `started_by = bf32624e-3334-425d-b694-c5944b0c66f0` (Simran).
- `inventory_control_attempt` — **0 rows** in the last 7 days from anyone.
- Yet `warehouse_inventory` IS being mutated today by her account — but only via `pack_dispatch_line` and `receive_purchase_order` (her normal pack + receive flow, not via inventory-control corrections).

The data layer and RLS are not blocking anything. **The edits never reach the backend at all** because the FE rejects them at the `if (!canEdit || !session)` early-return guards before any RPC is called.

## Root cause

`/field/inventory/page.tsx` has **two buttons that both sound like "Inventory Control"** and behave very differently. Simran is tapping the wrong one:

| Where                                 | Label                     | What it does                                                                                                                                      | Requires                                           |
| ------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| **Orange bar above the search input** | `Start Inventory Control` | Calls `start_inventory_session` RPC. Opens a real DB session. Persists to localStorage. This is the ONLY thing that unblocks edits.               | `warehouseId` not null + role in `SESSION_ROLES`   |
| **Header top-right**                  | `+ Inventory Control`     | Flips local React state `controlMode=true` so the UI shows a "Save inventory control" bulk-save button at the bottom. Does NOT open a DB session. | `canEdit = Boolean(session && role in EDIT_ROLES)` |

Because the header button is `disabled={!canEdit}`, in theory she can't tap it without an open session. In practice on iPad / Chrome PWA, the `disabled-opacity:50%` styling is visually subtle, the button stays visible, and the moment localStorage shows a stale session-id (from a previous attempt that never made it to DB), `canEdit` flickers true and she gets in. Then every save dies at the `!session` guard.

Three concrete failure paths on this page all reach a silent early-return:

1. **Inline qty edit** (`saveInlineQty`, line 1240) — `if (!canEdit || !session)` (line 1253) → sets a tiny `✗` badge for 1.5s → returns. The local `inlineQtys[id]` state shows the typed value until the next `fetchData()` (focus / visibility refresh) snaps it back. That's the "revert" she sees.
2. **Bulk-save in control mode** (`completeControl`, line 723) — `if (!canEdit || !session)` (line 724) → 3-second `setControlMessage("Open an inventory-control session first")` → message fades, edits cleared.
3. **Status toggle** (`toggleBatchStatus`, line 1337) — `if (!canEdit || !session) return;` (line 1339) — **silent return, no feedback at all**. Row stays in the old status.

None of these paths emit a toast or modal. None call any RPC. Hence zero `inventory_control_attempt` rows.

The session bar at line 1719 (`StartInventorySessionBar`) is rendered above the search input. On the iPad screenshot CS shared, the keyboard occupies the bottom half, the search input is mid-screen, and the bar is scrolled off the top. She never sees it.

The same `StartInventorySessionBar` is also used by `/app/inventory` (the operator desktop page) and exhibits the same trap — though that page is admin-only and the workflow blast radius is smaller.

## Expected behaviour

1. Anyone who lands on `/field/inventory` with an `EDIT_ROLES` role sees an obvious, unmissable affordance to start a session — even with the keyboard open.
2. The two "Inventory Control" affordances are renamed so they can't be confused.
3. Every silent-fail edit path becomes loud: toast or modal, not a hidden text label.
4. Tapping the bulk-edit toggle re-verifies the session against the DB; no entering bulk mode without a confirmed open session.
5. Same fixes propagate to `/app/inventory` (the operator desktop page) via the shared `StartInventorySessionBar` and a small parent-side patch.

## Proposed design

Four FE changes — no backend, no migration. Roughly 80–120 lines across three files.

### Change 1 — Rename the header button (kill the name collision)

`src/app/(field)/field/inventory/page.tsx` line ~1681:

```diff
-              <button
-                onClick={enterControlMode}
-                disabled={!canEdit}
-                className="…blue-600…"
-                title={
-                  !canEdit
-                    ? "Open an inventory-control session above to begin"
-                    : undefined
-                }
-              >
-                + Inventory Control
-              </button>
+              <button
+                onClick={handleEnterBulkEdit}
+                disabled={!canEdit}
+                className="…blue-600…"
+                title={
+                  !canEdit
+                    ? "Tap Start Inventory Control at the top to begin"
+                    : undefined
+                }
+              >
+                + Bulk Edit
+              </button>
```

Apply the same rename to `/app/inventory` for consistency.

### Change 2 — Sticky session bar

`src/app/(field)/field/inventory/page.tsx` line ~1715–1727 — wrap the bar in a sticky container:

```diff
-      <div className="px-4 py-4">
+      <div className="px-4 py-4">
-        <div className="mb-3 space-y-2">
+        <div className="sticky top-[var(--field-header-height,56px)] z-30 -mx-4 px-4 mb-3 space-y-2 bg-white/95 backdrop-blur dark:bg-neutral-950/95 pb-2 border-b border-neutral-100 dark:border-neutral-800">
           <StartInventorySessionBar … />
           <CanaryIndicator />
         </div>
```

Apply the same wrapper on `/app/inventory`. The bar must stay anchored below the page header while the user scrolls and while the soft keyboard is open.

### Change 3 — Every silent-fail edit path becomes loud

Create a single shared helper in the page module (or in `src/lib/inventory/`):

```ts
function alertNoSession() {
  // Use the same alert() pattern as procurement/page.tsx for parity until
  // the project picks a toast lib. Unmissable on mobile.
  if (typeof window !== "undefined") {
    window.alert(
      "Inventory edits are locked. Tap 'Start Inventory Control' at the top of the page first.",
    );
  }
  // Scroll the bar back into view in case the keyboard hid it.
  document.getElementById("start-inventory-session-bar")?.scrollIntoView({
    behavior: "smooth",
    block: "start",
  });
}
```

Call it from all three silent-return sites:

- `saveInlineQty` (line 1253) — replace the silent `✗` badge with `alertNoSession()` + return.
- `toggleBatchStatus` (line 1339) — replace the silent `return` with `alertNoSession()` + return.
- `completeControl` (line 724) — replace the 3-second `setControlMessage` with `alertNoSession()` + return.

Add `id="start-inventory-session-bar"` to the bar's outer wrapper inside `StartInventorySessionBar.tsx` so the scroll target works.

### Change 4 — Re-verify session before entering bulk edit

In place of `enterControlMode` direct call from the header button (line 1682), wire a `handleEnterBulkEdit` that re-checks session against the DB rather than trusting the localStorage-derived `canEdit`:

```ts
async function handleEnterBulkEdit() {
  const supabase = createClient();
  // Re-verify by RPC, not the cached useInventorySession() value.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    alertNoSession();
    return;
  }
  const { data, error } = await supabase
    .from("inventory_control_session")
    .select("session_id")
    .eq("started_by", user.id)
    .eq("status", "open")
    .limit(1)
    .maybeSingle();
  if (error || !data?.session_id) {
    alertNoSession();
    return;
  }
  enterControlMode();
}
```

This kills the localStorage-flicker bypass: even if `canEdit` is briefly truthy from stale storage, the click won't enter bulk-edit unless a real open session row exists.

## Scope

In scope:

- The four FE changes above on `/field/inventory`.
- Apply Change 1 (rename), Change 2 (sticky), and Change 3 (loud failure) on `/app/inventory` for parity — the shared `StartInventorySessionBar` is the same component.
- Add `id="start-inventory-session-bar"` to `src/components/inventory/StartInventorySessionBar.tsx`.
- CHANGELOG.md entry (FE-only).

Out of scope:

- Adding `user_profiles.home_warehouse_id` (per-user default warehouse). Useful follow-up; not blocking Simran today.
- Auto-starting sessions on landing — rejected. Every session must be explicit so `started_by` honestly reflects intent.
- Backend changes — none needed.
- Replacing `alert()` with a proper toast primitive. Use `alert()` for parity until the project picks a toast lib; the loudness is what matters.

## Protected entities touched

None. Pure FE.

## Acceptance criteria

- [ ] Simran lands on `/field/inventory` and the orange "Start Inventory Control" bar stays visible at the top while she scrolls or types.
- [ ] The header button is renamed to `+ Bulk Edit`. Same on `/app/inventory`.
- [ ] Tapping `+ Bulk Edit` without a real DB session pops an `alert()` and scrolls the bar back into view. The bulk-edit mode does NOT activate.
- [ ] Editing a row's qty (inline) without a session pops the same alert. The local input value resets to the DB value.
- [ ] Tapping a status pill without a session pops the same alert. The status does not flip.
- [ ] After tapping the Start button in the bar, `inventory_control_session` has a row with `status='open'` for her user_id. Verify: `SELECT * FROM inventory_control_session WHERE started_by='bf32624e-3334-425d-b694-c5944b0c66f0' AND status='open'`.
- [ ] After her first qty save, `inventory_control_attempt` has a `result='success'` row. Verify: `SELECT COUNT(*) FROM inventory_control_attempt WHERE attempted_by='bf32624e-…' AND attempted_at >= now() - interval '1 hour' AND result='success'` returns ≥ 1.
- [ ] `warehouse_inventory.warehouse_stock` reflects her typed value after refetch (Barebells Salty Peanut at WH_CENTRAL: 24 → 20).
- [ ] No regression on `pack_dispatch_line` and `receive_purchase_order` — her normal warehouse flow still works (these write to warehouse_inventory through different paths and are not gated by inventory-control sessions).

## Edge cases

- **Keyboard open hides the bar.** Sticky positioning + `scrollIntoView` on alert dismiss covers this.
- **localStorage has a stale session_id.** Change 4 re-verifies against the DB, so the bypass is closed.
- **User switches warehouse tab mid-session.** Existing behaviour preserved — the session stays open under its original `scope_warehouse_id` until explicitly closed.
- **Two tabs open simultaneously.** Each tab reads its own localStorage but the DB session is the single source of truth. Save attempts in either tab will succeed only if the session row is `status='open'`.
- **Mobile narrow viewport with sticky bar overlap.** Test on iPad portrait (the screenshot device) — the bar's height should compress to fit, never overlap the row list scroll area.

## Verification

- [ ] `npx tsc --noEmit`
- [ ] `npm run build`
- [ ] `npm run lint`
- [ ] Manual: log in as `warehouse@boonz.test` on the iPad PWA. Land on `/field/inventory`. Confirm orange bar is visible immediately. Tap Start. Confirm bulk-edit unlocks. Edit Barebells qty 24 → 20. Save. Refetch. Confirm 20 persists.
- [ ] Manual: same flow on desktop `/app/inventory`.
- [ ] Manual: clear localStorage, sign back in, immediately try to tap `+ Bulk Edit` without tapping Start. Expect alert.
- [ ] DB check: `SELECT result, COUNT(*) FROM inventory_control_attempt WHERE attempted_at >= CURRENT_DATE GROUP BY result` — should see `success` rows by EOD.

## Decisions

- **Header button renamed to `+ Bulk Edit`** (not "Bulk Save" or "Edit Multiple") — describes what the local mode actually toggles. Keeps the name "Inventory Control" exclusively for the session-opening action so the team has a single mental model.
- **Sticky bar, not modal.** A modal forcing the user to start a session would be intrusive when she just wants to look. Sticky keeps the affordance always one tap away without blocking the view.
- **`alert()` for now, not a toast lib.** Project has no toast primitive imported broadly. `alert()` is universally loud, mirrors the `saveNewPO` pattern in `procurement/page.tsx`. Swap to a toast in a follow-up sweep when the project picks one.
- **DB re-verification on `+ Bulk Edit` tap.** Stricter than the current `disabled={!canEdit}` check. Kills the localStorage-flicker bypass that explains how Simran ever got into bulk-edit mode without a session.
- **Both pages get the fix in one PRD.** The shared `StartInventorySessionBar` component means most of the change lives there; per-page changes are minimal.

## Linked PRDs

- _(none — this is the first inventory PRD)_

## Linked memory

- [[reference_warehouse_status_manager_only]] — context for the Phase G P1 session model.

## Verbal unblocker (for today, until this ships)

Tell Simran: **scroll to the very top of `/field/inventory`. There is an orange bar above the search box that says "Inventory edits are locked." Tap the "Start Inventory Control" button inside that bar. Once the bar turns blue and says "Inventory control session open," her edits will save.** The `+ Inventory Control` button at the top-right is NOT the same thing — it only toggles bulk-edit mode after the session is already open.

## Rollout plan

1. **Stax** implements the four changes (Changes 1–3 on both pages, Change 4 on `/field/inventory` first).
2. Diff goes to Cody for Article 3 audit (confirm no new direct table writes added).
3. Deploy to Vercel.
4. CS verifies in production with `warehouse@boonz.test`.
5. Mark `status: Done` with the commit SHA in a `done_summary` block.
