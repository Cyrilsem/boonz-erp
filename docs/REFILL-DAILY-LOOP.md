# The daily refill loop

Six steps. One owner each. The button or the call for each. PRD-127 (2026-09-17/18) added the
first one -- brief, propose, converse, adjust, push -- ahead of what was previously the first
step of the day.

| When                      | Who              | Does                                                                                                                                                                                                                               | With                                                                                                                                                                                                                                                                             |
| ------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Any time before 19:00** | CS               | **Brief**: asks what tomorrow looks like. **Propose**: reads the rendered summary. **Converse**: pushes back in plain language on anything wrong. **Adjust**: re-asks with the correction folded in. Repeats until it reads right. | `propose_refill_plan(plan_date, machine_names, overrides)` -- writes nothing, safe to call as many times as needed. `overrides` carries one-off corrections ("put 6 on AMZ-1046 A02, not 4"); a durable "never recommend this again" goes through `add_refill_directive` instead |
| **19:00**                 | CS               | **Push**: confirms tomorrow's machines and the car split, now already knowing what to expect                                                                                                                                       | FE: pick list, tick, Confirm and Build. Or by message: "confirm and build: AMZ ×5, OMDCW car 2; Mirdif car 1"                                                                                                                                                                    |
| **19:05**                 | CS               | Reads the exception list on the draft, five lines or fewer, and presses Approve                                                                                                                                                    | FE: Draft, Exceptions, Approve. Approve stitches and pushes in one go                                                                                                                                                                                                            |
| **06:00**                 | Simran / Anthony | Pack from the pack screen. Mark All Packed when done                                                                                                                                                                               | FE: Packing                                                                                                                                                                                                                                                                      |
| **On the road**           | Jojo / Anthony   | Field app, line by line. Every return gets a reason. Complete Dispatch per machine                                                                                                                                                 | Field app                                                                                                                                                                                                                                                                        |
| **17:00**                 | Simran           | Warehouse Confirmations: count what came back, split by expiry or flavour where needed, Confirm                                                                                                                                    | FE: Inventory, Start Inventory Control, Confirm                                                                                                                                                                                                                                  |

The propose/converse/adjust loop and the 19:00 Confirm and Build are deliberately two different
calls, not one: `propose_refill_plan` never writes, so CS can iterate on it freely before
`confirm_and_build`/`engine_add_pod` ever touch `pod_refill_plan`. Nothing about 19:00-17:00
below changed.

**What triggers a message to Fable.** An exception the rules do not cover, a machine that
will not complete, a count that does not match. Nothing else. A normal day has no message.

**What CS never has to do again.** Waive a gate. Rewrite a shelf. Move a Remove leg. Run SQL
to close a machine. Restore venue lines.

**Once a week, Sunday.** Read `v_pod_weimi_drift` for the fleet, read the substitution rules
table, add or retire rules. Read `refill_directives` (active blocks) and retire anything that's
stopped being true (a product is back in stock, a machine is no longer paused). Ten minutes.

**Final mandatory steps, every loop.** All four gates below must pass before a loop is called
done. Any failure means the run is not finished: fix it or roll back, do not report success with
an open gate.

1. **Parity check.** Every migration applied to prod this run is on main before the run is
   called done. A migration applied directly against prod (via the Supabase MCP or otherwise)
   and never landed as a file on main is not finished work, it is drift waiting to bite the next
   person who reads the repo instead of the database. Confirm each one against
   `pg_get_functiondef` (or the equivalent for the object touched) before checking this off, not
   just that a file with the right name exists.

   **Filename-vs-applied-timestamp check (added 2026-09-30, PRD-137).** The `apply_migration`
   tool records each migration's version in `supabase_migrations.schema_migrations` as the
   timestamp it actually ran, not the filename it was given. If you pick a filename in advance
   (e.g. to match "now" when you started drafting it) and the apply happens later, the recorded
   version and the filename drift apart -- the same class of bug as the "Round 2.5" filename
   incident already documented in CLAUDE.md, just triggered a different way. Before checking off
   the parity gate, run:

   ```sql
   select version from supabase_migrations.schema_migrations
   where version >= '<start of this run, UTC>' order by version;
   ```

   and confirm each returned version matches the filename timestamp of the corresponding file on
   main exactly. If any differ, rename the file (migration and its rollback) to the recorded
   version and update any "Rollback:" comment inside it that references the old name, then
   re-commit before calling the run done.

2. **Overload gate.** Run this query. Any row returned means the run FAILS: roll back the
   migration that caused it before doing anything else.

   ```sql
   WITH pairs AS (
     SELECT f_short.proname,
            pg_get_function_identity_arguments(f_short.oid) AS short_sig,
            pg_get_function_identity_arguments(f_long.oid) AS long_sig
     FROM pg_proc f_short
     JOIN pg_proc f_long
       ON f_short.proname = f_long.proname
      AND f_short.pronamespace = f_long.pronamespace
      AND f_short.oid <> f_long.oid
      AND f_short.pronargs < f_long.pronargs
     WHERE f_short.pronamespace = 'public'::regnamespace
       AND (SELECT array_agg(val ORDER BY ord) FROM unnest(f_short.proargtypes::oid[]) WITH ORDINALITY AS t(val, ord))
           =
           (SELECT array_agg(val ORDER BY ord) FROM unnest(f_long.proargtypes::oid[]) WITH ORDINALITY AS t(val, ord)
             WHERE ord <= f_short.pronargs)
       AND (f_long.pronargs - f_long.pronargdefaults) <= f_short.pronargs
   )
   SELECT * FROM pairs;
   ```

   This finds any two same-named public functions where the shorter argument list is an exact
   prefix of the longer one and every extra argument on the longer one has a default -- the exact
   shape `CREATE OR REPLACE` produces a brand new overload instead of replacing the old function,
   the moment a migration adds a trailing `DEFAULT`-valued parameter without also dropping the old
   signature. This is not hypothetical: it broke `insert_driver_remove_line` on 2026-09-29
   (hotfixed same night) and, once this query was written correctly, it also found a second,
   older, previously undetected case on `propose_decommission_plan` (5-arg vs 6-arg). The same
   check also runs nightly on its own via `check_ambiguous_function_overloads()` and
   `cron.job` `check_ambiguous_function_overloads_nightly`, see item 4 below, so a bad overload is
   still caught on nights with no loop at all -- but do not rely on the cron alone during a loop,
   run the query directly as this gate.

3. **Signature rule.** A migration that changes the argument list of any RPC called from
   `src/app/(field)` must `DROP FUNCTION` the old signature in the same migration, not leave it
   standing next to the new one "for compatibility." A stale overload left behind is exactly gate
   2's failure condition. `CREATE OR REPLACE FUNCTION` never removes an old signature on its own,
   it only replaces a function whose argument types match exactly.

4. **App smoke test, before 06:00 Dubai.** Using the deployed app as the test warehouse and
   driver users (see CLAUDE.md / project memory for current test accounts; `driver@boonz.test` is
   a `warehouse`-role account, not `field_staff` -- confirm the actual role before relying on a
   refusal or an allow), on a real or synthetic test machine: pack a line, add a return, add a
   return variant, add an intra-machine move. Any failure means roll back the night's migrations
   and report; do not proceed to declaring the run done. This is the step that catches a working
   `apply_migration` call whose function only breaks on first real use (already this repo's own
   standing rule from PRD-131: every migration that creates or replaces a function ends with one
   rolled-back smoke call, this is the same discipline extended to the deployed app itself).

A nightly cron alert (`check_ambiguous_function_overloads_nightly`, `monitoring_alerts` severity
`critical`) runs gate 2's query independently of any loop, so a bad overload introduced outside a
loop run (a manual hotfix, a one-off `apply_migration` call) is still caught the same night.
