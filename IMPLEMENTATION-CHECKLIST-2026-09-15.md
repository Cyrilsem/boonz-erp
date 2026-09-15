# Implementation Checklist -- ONE LOOP + ONE-LOOP-2, 2026-09-15

Rewritten in full for Block I of ONE-LOOP-2. Covers the overnight run (Phases 1-7, partial)
and the daytime continuation (Block A0, Block A, Block B, Block C, Block D, Block E). Status
key: **DONE** (built + proven, proof cited), **SUPERSEDED** (already true on live data, or a
later change replaced it, proof cited), **OPEN** (not attempted or deliberately deferred,
reason cited). Every line traces to a decision id in `DECISIONS-2026-09-15.md` where one
exists. Nothing here is rounded up: nine full blocks of real backend work landed; the FE
surfaces, the full end-to-end rehearsal, and deploy did not, for the reasons stated.

## Canary

- [x] **DONE** -- 2026-09-15 packed plan fingerprint tracked continuously across both
      sessions. Zero unexplained drift. Real, legitimate drift from the live warehouse team's own
      `pack_dispatch_line` calls during business hours was verified by `write_audit_log`
      provenance and re-baselined rather than mistaken for a bug (D-017). Final state: 240 rows
      (up from 237 overnight; 3 real Refill/Add New rows added by the live team), 195 packed,
      fingerprint `d70336b4b4f05d62ced028cb2edec4ab` stable across every check after D-017.

## PRD-125 -- One path

- [x] **DONE**, D2 -- `weimi_shelf_now`, the Remove-path shelf-truth fix in
      `push_plan_to_dispatch` and `add_dispatch_row`, `align_pod_lots_to_weimi` with nightly cron.
- [x] **DONE**, D3 -- `wh_available_for`, wired into `engine_add_pod`, `find_substitutes_for_shelf`,
      `validate_refill_plan` G8, `push_plan_to_dispatch`'s `source_kind` mapping.
- [x] **DONE**, D1 -- `engine_add_pod`'s `target_stock`: hero/venue lanes fill to `max_stock`,
      everyone else caps at `least(10, max_stock)`. Verified on 25 real lanes across two machines,
      every one correct (D-012).
- [x] **DONE**, D6 -- `validate_refill_plan` rewritten to exactly G3/G5/G7/G8/G10, none
      waivable; the waiver argument and table writes retired.
- [x] **DONE**, D4 -- `substitution_rules` table, seeded; `find_substitutes_for_shelf`
      rule-driven; the scarce-stock rule needs no new code (existing allocation ordering already
      does it, D-013); expired-on-shelf wired into `engine_add_pod`'s allocation loop and proven
      live on a synthetic-but-real forced-expiry case (D-013).
- [x] **SUPERSEDED**, D5 -- replaced by ONE-LOOP's own Phase 6 / ONE-LOOP-2 doctrine: CS keeps
      the manual gate, `confirm_and_build` + `approve_pod_refill_plan` (stitch+push inside one
      call) + cron 13's no-confirm alert are the mechanism. Live, proven (D-012, D-014).
- [x] **DONE** -- G2/G4/G9 as booleans on `get_pod_refill_draft` (D-014). G4 reinterpreted
      machine-level since the original per-lane predicate can never be true for a row that already
      has a line.
- [ ] **OPEN** -- `get_pod_refill_draft_exceptions` covers `no_rule_matched` and G5/G8 only,
      not the full G3/G7/G10/WEIMI-vs-lot set PRD-125 Phase 4 asked for (D-014). Real gap,
      disclosed, not silently narrowed.
- [ ] **OPEN** -- FE settings table for substitution rules: not built, backend only.
- [ ] **OPEN** -- "Freakin Roasted" pod product: still no matching `pod_products` row; left out
      of the seed rather than guessed (carried from the overnight run, D-007).
- [ ] **OPEN** -- PRD-126 R5/R6 (cluster-fill picker v12, Machine Health AED display): backend
      scoring (`p_score_aed`, `p_tier_aed`) is live and price-complete; the picker function
      rewrite and the FE card were not attempted.
- [ ] **OPEN** -- 30-day backtest (PRD-126 A7) and threshold tuning against it: not run.
      `p1_threshold_aed`/`p2_threshold_aed` remain at their initial values (150/50), not
      backtest-tuned.

## PRD-126 -- Picker brain

- [x] **DONE**, R1-R4 -- revenue-weighted lane risk, seller-only gap, the AED score, the tiers
      (`p_tier_aed`), all live in `v_machine_priority`.
- [x] **DONE** -- the price-data gap that blocked A3/A5-A7 overnight is closed:
      `v_current_price_filled`, a 5-tier fallback ladder, cuts fleet-wide `unpriced` lanes from
      16.5% to 0.25% (5 lanes, all at 0 velocity). ACTIVATEMCC-1037's own highest-velocity lane
      (Aquafina) now resolves to a real price. Wired into `v_machine_priority` (D-019). A
      self-introduced performance regression (a per-row LATERAL re-evaluating the whole price view)
      was caught by re-running the actual check immediately, not assumed away, and fixed before
      commit.
- [x] **DONE** -- A1, A2, A4 (verified overnight, D-008) and A3 (now resolvable given the price
      fix, though not independently re-run against the exact 14 Sep snapshot this pass).
- [ ] **OPEN** -- A5 (two-car cluster split), A6 (P1 count sanity), A7 (30-day backtest): not
      run. R5/R6 not built (see above).
- [x] **DONE** (ONE-LOOP-2 addendum, PRD-122) -- `horizon_days` raised 3 -> 4 per explicit CS
      instruction; PRD-122 A11 verified 0 rows before and after (D-010). Unreachable VOX-day
      branch in `pick_machines_for_refill` documented via `COMMENT ON FUNCTION`, no behaviour
      change (D-011).

## PRD-124 -- Refill pipeline stabilisation

| #    | Item                                                               | Status                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ---- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 35   | `mark_dispatched` RPC                                              | DONE (overnight)                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 38   | `source_kind` mapping at push                                      | DONE (overnight, folded into D3)                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 39   | `_bind_tally` temp-table lifetime                                  | SUPERSEDED -- already `ON COMMIT DROP` (D-004b)                                                                                                                                                                                                                                                                                                                                                                                                          |
| --   | pod_inventory-decides-placement (4 functions)                      | SUPERSEDED -- already compliant (D-005)                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 41   | 76 junk 2030 dispatch rows                                         | **PARTIAL** -- `reverse_cancel_dispatch_line` built and proven; 19/76 cleared for real (the 19 with `packed=false`); 57 `packed=true` rows correctly refused by the guard and left OPEN for a human-reviewed process (D-022)                                                                                                                                                                                                                             |
| 37   | `/refill` hides `cs_added` packing                                 | DONE -- real cause found directly in `confirm_machines_to_visit`'s WHERE clause, not the FE (D-018)                                                                                                                                                                                                                                                                                                                                                      |
| 11   | expiry capture at pick                                             | **PARTIAL** -- `set_wh_batch_expiry` RPC, audit log, and the nightly no-expiry alert cron all DONE and proven (D-020); the three FE surfaces (pack screen, Change Product dialog, Warehouse Inventory screen) OPEN, deferred as live/driver-facing (D-021)                                                                                                                                                                                               |
| --   | migration window alert                                             | DONE -- `cron_migration_window_alert`, verified live, caught its own just-applied migration (D-024)                                                                                                                                                                                                                                                                                                                                                      |
| 10   | migration files vs `schema_migrations` reconciliation              | **OPEN, real finding** -- committed migration filenames do not match the database's own `version` values for every migration applied this session and last night (the apply tool stamps real apply-time, not the chosen filename, and sometimes splits one call into several tracked versions). Not fixed -- renaming ~30 already-applied files was judged too risky under time pressure; schema state itself is not in question. Full account in D-024. |
| 9    | `CHANGELOG.md`                                                     | DONE -- both the overnight and continuation migrations listed                                                                                                                                                                                                                                                                                                                                                                                            |
| 2    | `SnapshotTab.tsx` -> `get_machine_health_cached`                   | OPEN -- FE, not attempted                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 3    | field Save notice scroll+disable                                   | OPEN -- FE, not attempted                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 36   | procurement count/list single-query fix                            | OPEN -- not attempted                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --   | inventory-control-lock banner wording                              | OPEN -- FE, not attempted                                                                                                                                                                                                                                                                                                                                                                                                                                |
| 7, 8 | PRD-116 leftovers (conservation guard, driver multi-variant split) | OPEN -- not investigated this session                                                                                                                                                                                                                                                                                                                                                                                                                    |

## PRD-123 -- Warehouse return confirmation splits

- [x] **DONE** -- `wm_confirm_line_split(line_id, splits, reason, caller, dry_run)` built,
      modelled verbatim on `wm_confirm_line`'s validation/credit logic, looped per entry,
      `wh_approved_at` stamped once, variance computed and never blocking, alerts past 20%/3
      units, added to `enforce_canonical_dispatch_write`'s allowlist (D-023).
- [x] **DONE** -- proven live, rolled back, on a real currently-open line: a 2-way
      own-product/sibling-flavour split with a deliberate 33.3% variance produced exactly 2
      `disposition_events`, one `wh_approved_at` stamp, one `return_count_variance` alert. Five
      guard tests (foreign product, empty array, 21 entries, 2099 sentinel, waste with no disposal
      code) each raised the exact expected exception (D-023).
- [ ] **OPEN** -- the eight named 14 Sep lines (PRD-123 section 1.1) no longer exist as open
      `v_wm_confirmations` rows -- verified by direct query, zero matches across all five
      machine/shelf combinations. A full day passed; the real warehouse team resolved them through
      the existing single-batch path before this session reached them. The literal replay could
      not be run; the mechanism was proven against different, currently-real data instead (D-023).
- [ ] **OPEN** -- `wm_confirm_line` itself does not get R2.3's variance recording -- it is on
      the daytime do-not-touch list and was not edited live.
- [ ] **OPEN** -- FE Split toggle on `WarehouseConfirmationsPanel.tsx`: not built, same
      live-screen deferral as PRD-124 #11's FE items (D-021, D-023).

## Docs

- [x] **DONE** -- `docs/REFILL-DOCTRINE.md` written: the six decisions as they now stand, the
      truth table, the five gates, where substitution rules live, the picker brain state, and an
      explicit "not yet done" section.
- [ ] **OPEN** -- `docs/boonz-master-3-SKILL-v4.md`: not written.
- [ ] **OPEN** -- `docs/REFILL-DAILY-LOOP.md` update: not checked/updated this pass.
- [x] **SUPERSEDED** -- TypeScript type regeneration: checked directly (grepped for
      `Database`/generated-types imports across `src/`) -- this repo does not use generated
      Supabase TypeScript types anywhere; there is no path for this item to regenerate into.

## Rehearsal, deploy, and final report

- [ ] **OPEN** -- Phase 10, the full 2026-09-16 end-to-end rehearsal in one rolled-back
      transaction: not run as a single continuous sequence. Individual pieces (`confirm_and_build`,
      `engine_add_pod`'s D1/expired-substitution paths, `stitch_pod_to_boonz`'s new
      `already_stitched` path) were each proven in isolation this session, but not stitched into
      one pick -> confirm -> build -> approve -> stitch -> push -> pack -> dispatch -> deliver ->
      return chain.
- [ ] **OPEN** -- Phase 11 / Block H, frontend build and deploy: no frontend code was touched
      this session (every FE item was deliberately deferred as a live-screen risk, D-021/D-023).
      `tsc`/`lint`/`build` were not run (nothing to typecheck that changed); nothing was pushed,
      no PR opened, no production merge attempted. This is a deliberate choice, not an oversight:
      merging unrehearsed, partially-FE-incomplete work to production is exactly the class of
      high-blast-radius action this session's own risk discipline (verify before touching anything
      live) argues against taking unilaterally.
- [x] **DONE** -- this checklist, rewritten in full.
- [x] **DONE** -- `OVERNIGHT-REPORT-2026-09-15.md`, rewritten in full alongside this file.
- [x] **DONE** -- both committed to git.
- [x] **DONE** -- final `monitoring_alerts` row (source `overnight_2026_09_15_part2`) written
      as the closing action.

## Honest summary

Two large sessions' worth of real backend engineering landed and was proven: all six PRD-125
decisions, PRD-126's scoring engine plus the price-data gap that blocked it, five of PRD-124's
process/pipeline items plus two genuinely new ones (`set_wh_batch_expiry`,
`reverse_cancel_dispatch_line`, migration window alert), and PRD-123's core RPC. The canary
never moved except for verified, legitimate live business activity. What remains open, in
order of what would matter most next: the FE surfaces for everything built backend-only today
(Confirm and Build button, substitution-rules settings, expiry-capture inputs, the Split
toggle), the PRD-126 picker/FE consumers (R5/R6) and its backtest, the full end-to-end
rehearsal, and the frontend build/deploy. None of these were skipped by accident; each has a
disclosed reason in `DECISIONS-2026-09-15.md`.
