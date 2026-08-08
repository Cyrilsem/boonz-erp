# PRD-111 — Field PWA: Pack-Ahead Date Toggle (Today / Tomorrow)

**Status:** APPROVED by CS 2026-08-08 · **Owner:** Stax-class FE unit, executable by Claude Code
**Scope class:** FE-only. Zero backend, zero migrations, zero RPC changes, zero protected-entity writers.
**Repo:** boonz-erp (Next.js, Vercel). **Deploy:** git push → Vercel production.

## 1. Context and problem

The warehouse manager works EXCLUSIVELY on the field PWA (`/field`). Every field surface is
hard-coded to `getDubaiDate()` (today). The admin `/refill` page already has a Today/Tomorrow
toggle (`RefillPageClient.tsx` → `showTomorrow` → `selectedDate` prop), but she has no access to
`/refill` by role.

Real incident (2026-08-08): CS pushed the AMZ plan dated Sunday 08-09 so the team could pack
Saturday. The plan was invisible on `/field/packing` (today-only query); packing had to run off an
ad-hoc PDF. This PRD closes that gap permanently: **pack-ahead is a standing operating pattern**
(weekend routes, early-morning dispatches), not a one-off.

## 2. Goal

On the field PWA, a packer can flip between **Today** and **Tomorrow** and run the full packing
flow against the selected date. Default remains Today. Driver-facing flows are untouched.

## 3. Non-goals (explicitly out of scope — do NOT build)

- Arbitrary date picker / past dates (stale-plan packing risk). Exactly two values: today, tomorrow.
- Any change to `/field/pickup`, `/field/trips`, driver receive flows (trips already reads a
  yesterday..today window by design — leave byte-identical).
- Any RPC, view, table, cron or policy change. `pack_dispatch_line` is dispatch_id-keyed and
  date-agnostic; `confirm_machine_packed` already takes `p_dispatch_date`. The server is ready.
- No change to `/refill` (already has the toggle).

## 4. Functional spec

### 4.1 Shared date state

- New tiny helper/hook `useFieldPackDate()` in `src/app/(field)/field/_lib/` (or equivalent):
  returns `{ selectedDate, isTomorrow, setTomorrow(bool) }` where
  `selectedDate = isTomorrow ? dubaiTomorrow() : getDubaiDate()`.
- Persist selection in the **URL query param `?d=tomorrow`** so it survives navigation from the
  packing list into `/field/packing/[machineId]` and refreshes. No localStorage.
- Reuse the exact Dubai-date derivation already used by `RefillPageClient.tsx` (copy the
  `d.setDate(d.getDate() + 1)` pattern); do NOT reimplement timezone logic.

### 4.2 Surfaces that gain the toggle (packer-facing only)

1. **`/field/packing/page.tsx`** (machine list)
   - Segmented control at top: `[ Today ] [ Tomorrow ]`. Default Today.
   - All three queries currently pinned to `today` (`refill_dispatching`,
     `v_dispatch_pack_progress`, `v_machine_pack_status`) switch to `selectedDate`.
   - When Tomorrow is active, show a persistent amber banner: `⚠ Packing for TOMORROW <date>` so
     nobody packs the wrong day by accident. Machine cards link through with `?d=tomorrow`.
2. **`/field/packing/[machineId]/page.tsx`** (pack detail)
   - Read `?d=` param → `selectedDate`. Same amber banner when tomorrow.
   - EVERY occurrence of `getDubaiDate()` / `today` used as a **dispatch-date filter or RPC arg**
     switches to `selectedDate`. Known call sites from the audit (re-derive live, do not trust
     line numbers): the dispatch-line queries (~L410, L436, L1083), and CRITICALLY the
     `p_dispatch_date` args (~L1540, L2213) — `confirm_machine_packed` MUST receive the selected
     date or tomorrow's confirmation will silently target today (the exact class of silent-wrong
     this codebase hunts).
   - Timestamps for audit fields (`packed_at`-style `new Date().toISOString()`) stay real time —
     only DISPATCH-DATE semantics follow the toggle.
3. **`/field/not-filled/page.tsx`** — same toggle + banner (packers resolve not-filled there).
4. **`/field/page.tsx` (home)** — the packing badge/count may stay today-only this iteration
   (non-blocking); if trivial, show `today + tomorrow` counts as `N (+M tomorrow)`.

### 4.3 Guardrails

- If Tomorrow has zero dispatch lines, show the normal empty state plus `No plan pushed for
<date> yet` — never fall back silently to today's data.
- The toggle must never leak into pickup/dispatching/trips routes via shared components; scope
  the hook usage to the three surfaces above.

## 5. Acceptance criteria (all must pass before push)

1. `/field/packing` defaults to Today; behavior byte-equivalent to current prod when Today.
2. With a plan dated tomorrow (e.g. the live 2026-08-09 AMZ plan): flip → 5 AMZ machines appear
   with correct line counts; open a machine → lines match `refill_dispatching` for that date.
3. Pack a line on Tomorrow → `pack_dispatch_line` succeeds; `confirm_machine_packed` fires with
   `p_dispatch_date = tomorrow` and the confirmation lands on the tomorrow rows (verify in
   `v_machine_pack_status` for that date; today's rows untouched).
4. Amber banner visible on all tomorrow views; absent on today.
5. `?d=tomorrow` survives list → detail → back navigation; hard refresh keeps the date.
6. `/field/pickup`, `/field/trips`, `/field/dispatching` diffs: **zero**.
7. `npm run build` clean (no new type errors); Vercel preview deploy renders both states.
8. Grep gate: no remaining `getDubaiDate()` used as a dispatch-date filter inside the three
   converted surfaces except via the hook.

## 6. Verification & deploy protocol

1. Branch `prd-111-field-date-toggle`; commit ONLY `src/app/(field)/**` (+ the hook file).
2. `npm run build` locally green → push branch → Vercel preview → walk acceptance 1–5 against
   the LIVE 2026-08-09 plan (read-only checks + at most one reversible pack/unpack on a 1-unit
   line, then restore its state).
3. Merge to main → Vercel production. Announce: "packers can now flip Today/Tomorrow on /field."
4. **Rollback:** revert the merge commit; surfaces return to today-only. No data migration in
   either direction, so rollback is always safe.

## 7. Constitution note (for Cody, informational)

Read-path FE change + existing RPC args only. No SECURITY DEFINER, no RLS, no writes outside the
already-canonical pack RPCs. Article 16 untouched: `v_dispatch_pack_progress` remains the pack
board's oracle, now date-parameterized in the query it already supported.

## 8. Execution note for Claude Code

The PRD-110 DONE-2 relay loop may be running in this repo (touches `supabase/migrations`,
`docs/**`, `scripts/**`). This PRD touches only `src/app/(field)/**` — no file overlap. Work on
the branch, do not `git add -A` from the repo root, and do not touch the execution log or
parking lot. This is a SINGLE-SESSION task, not a relay loop: finish, verify, push, report.
