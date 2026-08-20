# PRD-112 — Driver Self-Service Substitution + Day-Close Panel — Execution Report

Branch: `prd-112-driver-substitution` (from `main`)
Started 2026-08-08. AUTO MODE: CS business approvals pre-granted; Cody gate NOT pre-granted.
Concurrency: PRD-110 relay is live in the same tree. Only PRD-112 paths are staged/committed.

## Unit 1 — Discovery (DONE)

Live schema read via Supabase MCP (project eizcexopcuoycuosittm).

**Guards on `refill_dispatching` that a substitution UPDATE must clear**

| trigger                                                                       | verdict                                                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enforce_canonical_dispatch_write`                                            | needs the new RPC name **appended** to its writer allowlist, otherwise every substitution logs a `bypass_violation_log` row. Append-only edit; no predicate change.                                                                                                                     |
| `protect_packed_dispatch_row`                                                 | today only `app.rpc_name='edit_dispatch_product'` may move `boonz_product_id`/`pod_product_id` on a packed line. This is the sanctioned bypass PRD 4.1 names; the new RPC must be added to the same one-line exemption. Every other clause (machine/shelf/date immutability) untouched. |
| `prevent_duplicate_unstarted_dispatch`                                        | only fires for `filled_quantity = 0 AND packed = false`. Avoided by design: the RPC requires `p_filled_qty > 0` (a zero-fill is the not-filled flow, not a substitution). Guard body **byte-identical**.                                                                                |
| `tg_enforce_not_filled_zero`                                                  | would silently re-zero `filled_quantity` if the line sat at `pack_outcome='not_filled'`. RPC promotes the outcome to `partial`/`packed` when the driver reports a real fill.                                                                                                            |
| `trg_enforce_pack_via_rpc`, `trg_flag_multivariant_pack_without_confirmation` | only fire on `packed` false to true. The RPC never flips `packed`. Not touched.                                                                                                                                                                                                         |

**Reused objects**

- `edit_dispatch_product` — the pod-resolution cascade (shelf `slot_lifecycle` binding first, then per-machine `product_mapping`, then global default) is lifted verbatim, so `pod_product_id` cannot drift from `boonz_product_id`.
- `adjust_pod_inventory(p_machine_name, p_snapshot_date, p_lines, p_reason)` — the merge path the acknowledge calls. Role gate is `warehouse | operator_admin | superadmin | manager`, so CS qualifies and a driver never can.
- `refill_plan_output.dispatch_id` — the rpo backlink PRD 4.2 requires be kept in sync.
- `original_boonz_product_id` — already on `refill_dispatching`; preserved for settlement (PRD 4.4).

**Landmine found and designed around: pod double-credit.**
`receive_dispatch_line` already merges `p_filled_quantity` into `pod_inventory` for the line's _current_ `boonz_product_id`. Since substitution rewrites that column before the receive runs, a normal receive already credits the NEW product. An unconditional `adjust_pod_inventory` at acknowledge would therefore book the same units twice. The acknowledge is conditional on `item_added`: it writes stock only for a substituted line the receive never closed, and records which branch it took in the event payload.

**Second landmine: GUC clobber.** `adjust_pod_inventory` overwrites `app.rpc_name` with its own name. Any `refill_dispatching` write after that call would pass `enforce_canonical_dispatch_write` under the _wrong_ writer identity (the S-160 family recorded in the allowlist comments). The acknowledge RPC re-asserts its own `app.rpc_name` after every nested call.

Next: Unit 2 — migration draft.

## Unit 2 — Migration drafted (DONE)

Three append-only files, no existing migration touched:

| file                                                        | contents                                                                                                                                  |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `20260808230000_prd112_day_close_events_table.sql`          | `day_close_events` + RLS + grants + audit trigger                                                                                         |
| `20260808230500_prd112_guard_registration.sql`              | additive registration in the two dispatch guards                                                                                          |
| `20260808231000_prd112_substitution_and_day_close_rpcs.sql` | `driver_substitute_dispatch_line`, `acknowledge_day_close_event`, `acknowledge_day_close`, `v_day_close_events`, `day_close_checks(date)` |

Deviations from the PRD, both deliberate:

- **`p_source_tag` is a 6th argument** (PRD §3.1 lists five). §3.1.2 requires the call to be taggable `spot`, and threading that through free-text `p_reason` would have been a parser pretending to be a contract. Values are `venue | wh | spot`, enum-checked. No DEFAULT on any argument (`pronargdefaults = 0`), so no overload ambiguity.
- **The date rule is `dispatch_date >= today (Dubai)`, not `= today`.** PRD §3.1.1 says today. PRD-111 shipped a Today/Tomorrow pack-ahead toggle on `/field` eight hours before this PRD, so drivers now legitimately hold tomorrow's lines; an equality check would refuse them. Past dates are still refused - a closed day is settled history.

## Unit 3 — Cody constitutional review (DONE, ⚠️ PASS-WITH-CONDITIONS)

Articles checked: 1 (as revised by Amendment 005), 2, 3, 4, 5, 6, 7, 8, 12, 14, 16, plus Appendix A (Amendment 003) and the S-308 default-privilege rule. Not a rubber stamp - **two findings were blocking as drafted**:

1. **Article 3 / S-308 (blocking).** A table created in `public` is born with INSERT/UPDATE/DELETE granted to `authenticated` by the postgres default ACL (`authenticated=arwdDxtm`, confirmed live against `machines_to_visit`). The draft only had `REVOKE ALL ... FROM PUBLIC, anon`, which is the S-268 idiom and does not touch a grant held by `authenticated`. Fixed with an explicit `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ... FROM authenticated`.
2. **Article 8 (blocking).** No `audit_log_write` trigger on the new table, while every sibling in the family carries one. Fixed: `tg_audit_day_close_events`.
3. **Article 4.** `acknowledge_day_close` was an unlabelled SECURITY DEFINER. Fixed - it now sets its OWN name, not the delegate's.
4. **Article 6, consequence to disclose.** On a packed Boonz-sourced line the WH was already debited against the OLD batch at pack time. Substitution rebinds `from_wh_inventory_id` and never reverses that debit - correctly, since those units are on the truck and close through the returns flow. It was invisible. Fixed: `wh_debit_rebalanced: false` plus the prior batch id are recorded in the payload, so the stranded debit is something CS can see rather than has to know.
5. **Article 16.** The `SUM(pod_inventory.current_stock)` in the acknowledge is a ledger read for a ledger write; `v_live_shelf_stock` cannot serve it (WEIMI-derived, keyed on `pod_product_id`, while `adjust_pod_inventory` writes an absolute at ledger grain - sourcing a ledger write from telemetry would inject drift). Approved on the `receive_dispatch_line` precedent, with the reasoning written into the code.

All five conditions applied. **Not blocked - no `## PRD-112 BLOCKED` section is warranted.**

## Unit 4 — Applied and verified in pg_proc (DONE)

Applied in filename order via Supabase MCP. Verification is from the catalogue, not from the presence of a file:

- `day_close_events` grants read back as `authenticated: REFERENCES, SELECT, TRIGGER` - **no INSERT/UPDATE/DELETE**, `anon` absent entirely. S-308 hole proven closed.
- RLS enabled, 1 policy, 1 trigger (`tg_audit_day_close_events`).
- Four functions live, `pronargdefaults = 0` on all, `anon` holds EXECUTE on none.
- `protect_packed_dispatch_row` and `enforce_canonical_dispatch_write` both carry the new writer name.
- `prevent_duplicate_unstarted_dispatch` body md5 `b11581fe9540b3a12c67bf6d4d25d0fc` - untouched, as promised (acceptance 5, guard half).

Next: Unit 5 - golden fixture 112 on synthetic date 2030-07-15.

## Unit 5 — Golden fixture 112 (DONE, 21/21 green)

`golden.render` derives the date as `DATE '2030-01-01' + fixture_id`, so fixture 112 runs on **2030-04-23** - a date no other fixture uses. Production write bounds held: every planted row is synthetic-dated, the fixture **never deletes a protected row** (re-runs plant fresh rows instead of resetting old ones, so no DELETE and no guard gymnastics), and the `pod_inventory` write plus all four probes run inside subtransactions that are deliberately rolled back. PL/pgSQL variables survive the rollback, so the evidence is kept while the write is not.

The fixture encodes the real incident with three lines on VOXMCC-1005-0201-B0: a venue line substituted to a flavor that HAS a VOX sentinel (clean, unflagged), the actual Dark Chocolate -> **Coconut** line (Coconut has no VOX sentinel, so accepted and flagged), and a Boonz line substituted to a zero-stock product (accepted and flagged). Then CS acknowledges, stock moves once, and a second acknowledge writes nothing.

**Two defects the fixture caught in its own author's work:**

1. **The closed-day tripwire went red on the first run.** I had written the probe with `DATE '2029-01-01'`, reasoning "before the 2030 fixture date". But the rule compares against the _real_ Dubai clock, and 2029 is in the future of today - the probe proved nothing and the RPC correctly accepted it. Fixed to `2020-01-01`; it now returns `dispatch ... is dated 2020-01-01 and today (Dubai) is 2026-08-08 - a closed day cannot be substituted`. A tripwire that cannot go red is not a tripwire.
2. **Fixture 112 leaked `app.via_rpc`.** `golden.run_all` runs every fixture in ONE transaction and these GUCs are transaction-local, so a fixture that calls an RPC and walks away leaves `via_rpc='true'` armed for whatever runs next. Fixtures 18, 26, 67, 71, 72 and 74 each assert against exactly this (the S-197 class). Fixture 112 sorts last today so it could not have poisoned them - but that is an accident of its id, not hygiene. It now resets both GUCs and **pins the reset with its own assertion (seq 21)**.

## Unit 6 — Full golden sweep (DONE, 67/67 green)

**67 of 67 enabled fixtures run, 0 reds**, fixture 112 included.

`golden.run_all` in one call is not reachable through the Supabase MCP channel: the suite is ~21 minutes of wall clock and the channel caps a statement at roughly two minutes. I ran it batched in `fixture_id` order - the order `run_all` itself uses - so the transaction-local GUC carries forward as it does in a real sweep. Three fixtures (7, 37, 42) exceed the cap on their own and needed individual retries during quiet periods; all three came back green.

**A false alarm worth recording, because it looked exactly like a regression.** My first batch ran 25 fixtures in one `DO` block in an order of my choosing, and five fixtures went 0 -> 1 against PRD-110's `leg160 sweep A`. Every one of the five failed on the same assertion class: _"app.via_rpc does not leak out"_. Re-running each one alone in its own transaction returned 0 red. The cause was my batch order putting RPC-calling fixtures ahead of the residue checks inside a single transaction - the harness, not the migration. Adjudicating from `runs.n_fail` alone would have read this as a PRD-112 regression; it was not, and the fix was to run in `fixture_id` order.

**Infrastructure note, logged because it is a shared-resource fact and not a PRD-112 result:** the database returned `the database system is not accepting connections` once, and Cloudflare 521/525 twice, during this sweep. PRD-110's relay is hammering the same instance concurrently. I paced the remaining batches and waited for health checks to return 200 before resuming rather than retrying into a struggling instance.

Next: Unit 7 - FE.

## Unit 7 — FE (DONE)

Branch `prd-112-driver-substitution`, merged to `main` as `a011777`, production deploy
recorded in `docs/DEPLOYMENTS.md` (`boonz-mdcb2c98p`).

**The state Unit 7 actually found.** `ChangeProductDialog.tsx` and
`driverSubstituteDispatchLine` / `listSubstituteProducts` already existed on `main` -
swept there by the PRD-110 relay's `git add -A` in leg 164, not by a PRD-112 commit.
Both were imported by **no file**. So the backend had been live since Unit 4 and nothing
in the product could reach it: the driver still had no button, and CS still had no panel.
Unit 7 is the wiring plus the Day Close panel, not a rewrite.

| file                                 | change                                                      |
| ------------------------------------ | ----------------------------------------------------------- |
| `refill/DayCloseTab.tsx`             | new - the §3.3 panel                                        |
| `refill/RefillPageClient.tsx`        | "Day Close" tab, between Refill Dispatch and Log            |
| `field/packing/[machineId]/page.tsx` | Change product button, SUB badge, dialog, toast             |
| `field/trips/[machineId]/page.tsx`   | same, plus `action` / `dispatch_date` / `original_…` select |
| `field/AddDispatchRowDialog.tsx`     | the duplicate-guard sentence (acceptance 5)                 |
| `field/_actions/dispatch-edits.ts`   | em-dash removal only                                        |

**Three FE decisions worth recording, because each one is a place the obvious code is wrong.**

1. **The packing button is deliberately NOT behind `isReadOnly`.** Every other affordance on
   that card is. But a packed, picked-up line is the _normal_ case for a substitution - that
   is the entire 08-08 incident - so gating it there would have shipped the bug the PRD was
   written to kill. The RPC is the sanctioned way through the packed-row guard; the FE has to
   actually offer it in the state the guard fires.
2. **Mix cards are excluded.** A mix card aggregates several boonz variants behind one pod
   label, so "which product am I replacing" has no single answer, while the RPC works one
   `dispatch_id` at a time. Remove lines never reach the branch, which already matches the
   RPC's Refill / Add New gate.
3. **The trips list reaches back one day** (`gte(yesterday)`), and the RPC refuses a past
   date as settled history. Rendering the button there would have been a tap that can only
   fail. It is hidden for `dispatch_date < today (Dubai)`. "Never blocked" has to mean never
   _offered-then-refused_ too.

**A defect caught before it shipped.** The gaps builder compares and subtracts
`quantity` / `filled_quantity`, both postgres `numeric`. PostgREST does emit those as JSON
numbers (verified on the wire: `planned_qty 6 int`), but a string `"10" < "9"` would have
silently invented a shortfall gap for every two-digit line. Coerced once through `num()`.

**Lint.** The new tab lints **0 errors / 0 warnings**. The first draft added one
`react-hooks/set-state-in-effect` - the rule fires on any effect that reaches setState
before an await, which is why `SignalsTab` and `PendingRemoveApprovalsPanel` carry it.
Restructured into a pure `loadDayClose()` that returns data and holds no state, with
setState only inside the `.then` callback: the shape `RefillLogTab` and `/refill/drift`
already use. Repo-wide error count is unchanged from the `main` baseline of 98.

### Verification

`npx tsc --noEmit` clean. `npm run build` green (before the merge and again on merged main).

**The preview could not be walked, so the production deploy was walked instead.** The
branch preview alias
`boonz-erp-git-prd-112-driver-substitution-cyril-semaans-projects.vercel.app` is a
**64-character DNS label** and does not resolve at all - past the 63-byte limit, so this is
not an SSO problem, the host does not exist. Rather than skip the walk, I signed in against
production with the real test accounts (password grant) and drove the deployed app with a
hand-built `@supabase/ssr` session cookie:

| walk                                        | result                                                                        |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| `/refill` as `warehouse@boonz.test`         | HTTP 200, served HTML carries **Day Close** in the tab bar with the other six |
| `/field/trips` as `driver@boonz.test`       | HTTP 200, session accepted by middleware                                      |
| `/field/packing/<id>`, `/field/trips/<id>`  | HTTP 200 both                                                                 |
| deployed client chunks for `/field/packing` | contain `"Change product"`, `"SUB"`, `"already exists on this shelf"`         |

That last row is the one that matters: the shipped bundle, not the local build, carries the
new UI.

**Every data contract the new UI depends on, exercised through PostgREST as the real role**
(this is what catches a grant or RLS hole that reading `pg_proc` cannot):

| probe                                                        | as         | result                                                                                        |
| ------------------------------------------------------------ | ---------- | --------------------------------------------------------------------------------------------- |
| `v_day_close_events` full column list                        | warehouse  | 200, fixture rows render-shaped correctly                                                     |
| `day_close_checks(2026-08-10)`                               | warehouse  | 200, 4 green / 1 red (62 returns pending)                                                     |
| `product_mapping` picker query                               | **driver** | 200, 317 rows, 52 `venue_team` - the picker populates                                         |
| trips select incl. `action` / `dispatch_date` / `original_…` | **driver** | 200, all three columns present                                                                |
| gaps select incl. `shelf_configurations(shelf_code)` embed   | warehouse  | 200, 70 rows for today, embed resolves                                                        |
| `driver_substitute_dispatch_line` x3 malformed inputs        | **driver** | reachable and EXECUTE-granted; all three raise pre-write                                      |
| `acknowledge_day_close_event` / `acknowledge_day_close`      | warehouse  | **refused** - "role warehouse not authorized (CS closes the day)", event still unacknowledged |

**Acceptance.** 1 and 2 are proven at the RPC layer by golden fixture 112 (Unit 5) and the
FE now issues exactly that call from a JWT proven able to reach it. 3's read half is proven
above against the real fixture rows; its write half is fixture 112. 4 is proven live:
`day_close_checks` went red with 4 unreceived machines on 2026-08-09 and red on returns for
2026-08-10, so the checks track real state rather than always reading green. 5 is done -
the sentence is appended only when the message is the duplicate guard's (matcher tested
against the live wording), and `prevent_duplicate_unstarted_dispatch` still hashes
`b11581fe9540b3a12c67bf6d4d25d0fc`, byte-identical to the Unit 4 pin. 6 is Units 5-6. 7 is
build green, walked as above, merged.

**Two things I did NOT do, deliberately.**

1. **No live substitution on a real production line.** PRD §6 suggests a "live smoke on a
   1-unit line". There is no un-substitute RPC: it rewrites `boonz_product_id`, rebinds
   `from_wh_inventory_id`, appends an audit comment and opens a day-close event, on a line a
   driver is working today. Fixture 112 already performs exactly this sequence end to end on
   synthetic 2030 data and is green, and the probes above prove a real `field_staff` JWT
   reaches the same function, so the smoke would buy very little for an irreversible write to
   live operational data. **CS action if you want it anyway.**
2. **No browser-driven interaction test.** The buttons render client-side, so an HTTP walk
   cannot click them. Playwright is not installed and CLAUDE.md forbids adding packages
   unasked. The interaction path is covered by build + typecheck + the bundle grep + the RPC
   contract probes, not by a click.

## PRD-112 DONE
