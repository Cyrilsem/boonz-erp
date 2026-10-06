# PRD-139b running log

Start: 2026-10-06T05:03:13Z (09:03 Dubai). Hard stop: 2026-10-06T12:03:13Z (16:03 Dubai),
7 hours after start, which is sooner than the next 05:45 Dubai (that falls on 2026-10-07).

## Step 0

- Lock written and pushed: `docs/prds/PRD-139b.lock`, commit 4abeb71, then rebased past a
  benign `chore(deploy)` push race onto ce7ffef. No competing PRD-139b lock found.
- `git log --since="3 hours ago" --oneline origin/main` showed only this session's own
  lock/spec commits and the prior PRD-139 session's deploy-recorder and em-dash-cleanup
  commits (baab38c and descendants), already known and accounted for. No new external
  PRD-139 activity.
- Read `docs/prds/PRD-139-REPORT.md` and `docs/prds/PRD-139-log.md` in full. Findings for
  items 5, 6, 7, 9 copied below, re-checked against current main.
- Baseline SQL, all matched expected exactly, nothing else has touched prod:
  - anon-executable SECURITY DEFINER functions in public: 321 (expected 321).
  - storage buckets: 0 (expected 0).
  - top migrations: `20261006043408 prd139_item1_role_guard_fix_postgres_bypass`,
    `20261006043159 prd139_item1_user_profiles_role_guard` (expected exactly these two on
    top, confirmed).

## Carried-over findings (re-verified against current main this session)

**Item 5, `v_machine_pack_status`.** Re-confirmed consumers already read from the view
(not re-derived locally) in: `field/pickup/page.tsx:78`, `field/packing/page.tsx:100`,
`field/dispatching/page.tsx:66`, `field/packing/[machineId]/page.tsx:519` and `:2010`,
`field/packing/_lib/pack-messages.ts:45` (comment reference). So the FE repoint described
in the PRD is largely already done; the real remaining work is the view-definition bug
itself (`total_included = 0` vacuous-true, and the NOOK `pack_state` case). Will re-fetch
the live view definition before writing a migration.

**Item 6, `v_po_header`.** Re-confirmed via grep: `v_po_header` does not exist anywhere in
`src/` or `supabase/`. The same 6 files still use the `received_date IS NULL` /
`received_date = today` pattern: `field/page.tsx`, `field/receiving/page.tsx`,
`field/receiving/[poId]/page.tsx`, `field/orders/page.tsx`,
`app/procurement/page.tsx`, `app/inventory/page.tsx`. Clean slate, as reported.

**Item 7, Dispatch Detail Save.** Re-read the full `handleSave` function and its render
site in `field/dispatching/[machineId]/page.tsx`. Found the exact mechanism (more precise
than the original PRD-139 report, which cited line numbers in the 819-825 range that have
since moved): the full-screen "Dispatch Complete" card (`allDispatchedFromDB`, around line 914) is actually gated correctly, it is computed from DB state after `fetchData()`
re-fetches post-save, so a failed line's `dispatched` flag is correctly still false there.
The REAL bug is the compact inline "Save summary" banner at lines 1220-1232, rendered
whenever `saved` is true with no success check at all: `addedCount` (line 1099) counts
`lines.filter(l => l.action === "added").length`, pure local intent set when the driver
tapped Add, never reset to null on an RPC failure (the error path at lines 780-799 and
826-834 only writes to `invWarnings`, it never clears `line.action`). So after any line's
`receive_dispatch_line`/`driver_confirm_remove`/`return_dispatch_line` call fails, the
green "N added to machine" banner still shows the full intended count, while the specific
per-line error is only visible further down the page next to that line's row
(`invWarnings[line.dispatch_id]`, rendered around line 1333), easy to miss under a
reassuring green banner above. `insert_driver_remove_line` confirmed to still have no
explicit date argument (line 650), the RPC stamps `dispatch_date = CURRENT_DATE`
server-side, UTC not Dubai.

**Item 9, Pack screen.** Re-confirmed via grep: `p_edit_role` does not appear anywhere in
`field/packing/[machineId]/page.tsx`. `handleMarkAllPacked` location and the duplicate
"Skipped items" render blocks need re-reading at current line numbers before editing
(line numbers may have moved since the 5 Oct report).

## Item log

(Each item's entry appended below as it is worked, in the PRD's specified order:
2A, 2B, 3, 4, 6, 5, 7, 8, 9, 10, Phase 5 gates.)
