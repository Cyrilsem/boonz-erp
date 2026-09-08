# PRD-121 Report — build parity restore + machine-status writer gap

Repo: `boonz-erp`. Supabase `eizcexopcuoycuosittm`. All work on `main`, pushed and live.

## T1 — migration parity (5 prod-only migrations reconstructed)

Reconstructed byte-for-byte from `supabase_migrations.schema_migrations.statements` — never
re-authored, per D1. Both md5s below were recomputed fresh in this session (not carried from
memory) as: local = `md5 -q <file>`, remote = `md5(array_to_string(statements, E'\n'))`.

| version          | file                                                | local md5                          | remote md5                         | match |
| ---------------- | --------------------------------------------------- | ---------------------------------- | ---------------------------------- | ----- |
| `20260821094253` | `prd117_reconcile_delivered_consumer_stock.sql`     | `c1e96c9ecb25dd00e233f6f0257940ad` | `c1e96c9ecb25dd00e233f6f0257940ad` | ✅    |
| `20260821094348` | `prd117_1_reconcile_skip_legacy_outcome_rows.sql`   | `bbb55a370db3d801c2b7ba0e64c920e8` | `bbb55a370db3d801c2b7ba0e64c920e8` | ✅    |
| `20260824081149` | `commission_iris_1070_single_door.sql`              | `cde01f8f25d0d31c96e8063a25e2b7a6` | `cde01f8f25d0d31c96e8063a25e2b7a6` | ✅    |
| `20260907053215` | `prd119b_t1_repair_remove_leg_shelf_lot_rpc_v2.sql` | `a2cf237efaf694a87cc4285a28263289` | `a2cf237efaf694a87cc4285a28263289` | ✅    |
| `20260907053259` | `prd119b_t1_repair_remove_leg_shelf_lot_rpc_v3.sql` | `3fa23f69578a6b01993932e6aec29d0a` | `3fa23f69578a6b01993932e6aec29d0a` | ✅    |

All 5 matched on the first write; no body was "fixed" (the v2 file still carries the broken
`edit_kind='shelf_lot_repair'` value, per the stop condition). D2 exception recorded for
`prd118_i_commitment_expose_breakdown` (covered by the pre-existing combined file). Registered in
`MIGRATIONS_REGISTRY.md`. Commits `c1840c7`→`d7ee90b`, `92e20f3`→`e7c7296` (from the earlier segment
of this loop, before this session's context compaction).

## T2 — branch hygiene

`git branch -vv` (current):

```
  archive/weimi-api-2026-06             [origin/archive/weimi-api-2026-06]
  chore/drift-kill-2026-07-09           [origin/chore/drift-kill-2026-07-09]
  feat/prd-087-ui-uplift                [origin/feat/prd-087-ui-uplift]
  fix/prd-088-unify-plan-clock          [origin/fix/prd-088-unify-plan-clock: ahead 3, behind 1]
  fix/prd-099-approve-return-provenance [origin/fix/prd-099-approve-return-provenance: ahead 32]
  fix/swap-lines-refill-parity          [origin/fix/swap-lines-refill-parity]
* main                                  [origin/main]
  prd-022-po-price-entry                [origin/prd-022-po-price-entry]
  prd-113-internal-moves-expired-guard  [origin/prd-113-internal-moves-expired-guard]
```

Every branch has an upstream — acceptance criterion met. `backup/pre-rebase-20260831`:
`git cherry origin/main backup/pre-rebase-20260831` returned all 8 commits as `-` (fully merged by
content), deleted via `git branch -D` per D5. `prd116-fe-dialogs`: its sole commit `0fe8f35`
cherry-picked onto `main` (new SHA `c7b2c33`, clean auto-merge, created `src/components/PromptModal.tsx`),
tsc verified, pushed, then deleted. No `+` from any `git cherry` call — the STOP CONDITION never
triggered. 17 additional local-only branches (not named in the PRD's own E2) cleaned via
`boonz_git_cleanup.sh --apply`; two (`fix/prd-088-unify-plan-clock`, `fix/prd-099-approve-return-provenance`)
were correctly skipped by the script itself — each has its own unmerged remote branch — and are out
of PRD-121's explicit scope.

## T3 — tree hygiene

6 previously-dirty files (RPC_REGISTRY + 3 PRD docs, `src/app/(app)/app/pods/page.tsx`,
`src/app/(field)/field/config/machines/page.tsx`) diffed against `0fe8f35`'s file set (no overlap)
and against each other — confirmed pure prettier/formatting diffs via whitespace-squashed
comparison, zero functional change. Committed in two commits per D6: goal-command + docs together
(`40bd509`), the two FE files together (`b13bcf5`, formatter-only). The two PRD-121 doc files
themselves (spec + goal-command) committed this session as `abda7a8`.

## T4 — `set_machine_status`, the canonical writer

**Design (Dara-shape):** `machine_status_events` append-only audit table (old/new for all four
columns, reason, actor, `via_rpc`/`rpc_name`), RLS enabled with SELECT-only for `authenticated`
(S-308: the table's default INSERT/UPDATE/DELETE grants to `authenticated` were explicitly revoked,
not just left to RLS).

**Cody verdict:**

> **Verdict:** ✅ Approve
> **Articles checked:** 1, 3, 4, 5, 7, 8, S-308
> **Findings:**
>
> - Article 1/5 ✅ — `set_machine_status` is now the sole UPDATE path for the four columns on an
>   existing row; enforced at the grant layer (see REVOKE finding below), not just by convention.
> - Article 4 ✅ — sets `app.via_rpc`/`app.rpc_name`, validates role (`operator_admin`/`superadmin`/
>   `manager`) and `p_reason` (≥10 chars), `FOR UPDATE` row lock before read-modify-write.
> - Article 7/8 ✅ — `machine_status_events` is append-only (RLS + REVOKE, no UPDATE/DELETE policy),
>   one row written per call.
> - S-308 ⚠️→✅ — first attempt used a column-level `REVOKE UPDATE (status, ...) ON machines FROM
authenticated` alone. **Live fixture proved this a no-op**: `authenticated` already held a
>   table-wide UPDATE grant, and Postgres treats a whole-table grant as sufficient to update any
>   column regardless of a narrower column-level revoke. Fixed by `REVOKE UPDATE ON machines FROM
authenticated` (whole table) followed by `GRANT UPDATE (<58 other columns>)`. Re-verified via
>   `information_schema.table_privileges`/`column_privileges` and a `SET LOCAL ROLE authenticated`
>   fixture that the block now actually holds.
> - `repurpose_machine` — no change needed. Its old-row UPDATE sets `repurposed_at=CURRENT_DATE` in
>   the same statement (so the trigger's `IS NULL` precondition is already false), its new-row
>   INSERT already sets `adyen_status='Online today', adyen_inventory_in_store='Live'` and relies on
>   `status` DEFAULT `'Active'` — both satisfy the invariant with zero code change. Trigger is
>   `BEFORE UPDATE` only (not INSERT), matching the reconstructed T1 migration's own framing of the
>   gap as "on an existing row."
>   **Next action:** ship as `20260908062117_prd121_t4_set_machine_status_rpc.sql`. Register in
>   `RPC_REGISTRY.md`. Done.

**Fixture** (rolled-back transaction against prod, real `WH3_1064_0000_W0` row, run before the file
was written): (1) direct UPDATE as `authenticated` blocked by the REVOKE — **failed on the first
design, caught by this same fixture, fixed, re-run clean**; (2) direct UPDATE to `status='Active'`
with mismatched adyen labels rejected by the trigger; (3) `set_machine_status` succeeds, machine row
updated, exactly one `machine_status_events` row written; (4) `field_staff` caller forbidden; (5)
<10-char reason rejected; (6) status-only partial update leaves `adyen_status`/
`adyen_inventory_in_store` unchanged (NULL-param semantics). All 6 passed. Migration file written
and committed (`bec4231`) **before** `apply_migration` was called, then applied and re-verified
against `pg_proc`/`pg_trigger`/`information_schema` live (file presence is not proof of apply).

**FE rewiring** — `grep -rn "adyen_status|adyen_inventory_in_store|installation_date" src` found
**five** direct-write sites (one more than the PRD's own E4 named), all rewired to defer through
`PromptModal` to `set_machine_status`:

1. `src/app/(app)/admin/machines/page.tsx` — single-row save (`handleSave`/`confirmStatusChange`).
2. `src/app/(app)/admin/machines/page.tsx` — bulk `set_active`/`set_inactive` (fan-out, one reason).
3. `src/app/(app)/app/pods/page.tsx` — drawer edit diff.
4. `src/app/(field)/field/config/machines/page.tsx` — status dropdown (partial update, NULL for the
   other three columns since this page never edits them).
5. `src/components/config/MachineSetupConfigTab.tsx` — `adyen_status`/`adyen_inventory_in_store`
   only (this tab has no `status`/`installation_date` fields).

New-row creation (`add_new_machine`'s INSERT, the field-config "Add machine" form, CSV import) left
untouched — confirmed via `pg_proc` sweep that only `add_new_machine` and `repurpose_machine` write
these columns fleet-wide, both out of scope or already analyzed above. No cron job or edge function
touches these columns (`cron.job` / `supabase/functions` / `n8n/flows` all grepped clean). **No FE
write path was left un-rewired — the STOP CONDITION never triggered.** `npx tsc --noEmit` and
`npm run lint` both clean on every touched file.

## T5 — IRIS-1070 (the real first caller)

```sql
SELECT public.set_machine_status(
  'd5628a72-807a-4a64-9976-5d76139ae354', NULL, 'Online today', 'Live', NULL,
  'PRD-121 T5: IRIS-1070 commissioned 2026-08-25 ... fixing via the new canonical writer as its first real caller.',
  '38c282e3-7468-4071-99d0-0473e3a4818f'  -- operator_admin
);
-- before: {status: Active, adyen_status: Switched off, adyen_inventory_in_store: Pending Setup}
-- after:  {status: Active, adyen_status: Online today,  adyen_inventory_in_store: Live}
```

Three verifications, all green:

1. `SELECT count(*) FROM v_machine_eligibility_drift` → **0**.
2. `v_live_shelf_stock` for IRIS-1070 → **16/16** rows `is_eligible_machine = true`.
3. `v_shelf_sales_identity` for IRIS-1070 → **16** rows now present (0 before the fix — this is
   exactly what fed the drift view and what the refill picker chain reads).

## T6 — guards

**(a) Nightly assertion** — `check_machine_eligibility_drift()` (same family as
`check_expiry_unvalidated`/`assert_sales_names_resolved`), cron `check_machine_eligibility_drift_nightly`
at 20:05 UTC, alerts via `safe_monitoring_alert('machine_eligibility_drift', 'critical', ...)` with
machine, both adyen labels, and `age_days`. `age_days` appended to `v_machine_eligibility_drift`
(not inserted mid-list — the PRD-022 42P16 lesson) as `EXTRACT(day FROM now() - m.updated_at)`, an
approximation documented in the view's own comment (`machine_status_events.changed_at` is the
precise source going forward for any machine that has been through the RPC). Applied and verified
live: `status: "ok", drift_count: 0`.

**(b) `scripts/check_migration_parity.py`** — written (T6b named it `.sh` in the goal text; built as
`.py` to match the proven, already-live sibling pattern `scripts/check_prod_repo_drift.py` — same
dual-mode design, same reason: this repo has no local DB CLI/credentials). Compares
`schema_migrations` (≥`20260615000000`) against `supabase/migrations/*.sql` by name-substring,
`prd053a`/`prd118_i` hardcoded as permanent exceptions, non-zero exit on any miss. **Verified**
against a real 99-row manifest slice (0 false positives, `prd053a` correctly excepted) and against
an injected fake row (correctly flagged `MISSING`, exit 1).

**Not wired into CI** — this repo's only GitHub Actions workflow is the production-deploy recorder;
there is no existing pre-deploy test/build gate to hook the script into, and running it in CI would
need a `SUPABASE_DB_URL` secret added to the repository. That is a credential/infra change outside
what I can do myself — **flagging for CS**, not silently skipping: the script is real, tested, and
ready to wire in the moment that secret exists (`SUPABASE_DB_URL=... python3 scripts/check_migration_parity.py`
in a new or existing workflow step).

## T7 — prove it (`boonz_build_refresh.py`)

```
main_ahead_of_origin: 0
main_behind_origin:   0
untracked_migrations: []
local_only:           []
prunable_count:       0
dirty_count:          0
remote_count:         32   (all 32 non-main branches carry an upstream)
```

`python3 boonz_build_refresh.py` → `OK  103 PRDs · 33 branches · 1 worktrees · 0 dirty files`.

## Registries updated

- **RPC_REGISTRY.md** — `set_machine_status` + `enforce_machine_status_invariant` entry, the
  table-wide-grant gotcha, and the 5 rewired FE call sites.
- **MIGRATIONS_REGISTRY.md** — T1's 5 rows + D2 exception (from the earlier segment); T4's
  `20260908062117` row; T6a's `20260908063907` row.
- **METRICS_REGISTRY.md** — not touched. `v_machine_eligibility_drift`/`is_eligible_machine` are
  drift-detection objects, not a registered business metric with multiple consumers re-deriving it
  — Article 16 doesn't apply here, so no entry was needed.
- **CHANGELOG.md** — not updated this loop. Flagging honestly rather than fabricating an entry:
  this loop's practice (matching T1–T3's own commits) has been PRD-specific report files as the
  changelog of record; if CS wants a `CHANGELOG.md` line for this PRD specifically, say so and it's
  a one-line addition.

## Environment GREEN

T1–T7 all green. `v_machine_eligibility_drift` = 0. `boonz_build_refresh.py` reports 0 dirty, 0
untracked migrations, 0 local-only branches, 0 ahead/behind on main. All FE direct writers of the
four owned columns rewired with none left un-rewired. No stale PRD closed (D7).

## PRD-121 DONE
