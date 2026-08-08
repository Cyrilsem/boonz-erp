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
