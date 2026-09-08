# PRD-121 — Build Parity Restore + Canonical Machine Status Writer

Repo: `boonz-erp`. Supabase project `eizcexopcuoycuosittm`. Raised 2026-09-08 from the daily
build-drift check (8 signals). One loop, one PR-equivalent on `main`.

## 1. Problem

The 08-21 migration-parity reconciliation lasted 17 days. Today prod holds five migrations that git
cannot reproduce, two branches exist only on this laptop, the PRD-119b goal command that drove
07 Sep's prod changes is an untracked file, and one trading machine (IRIS-1070-0000-O1, 20 sales/7d)
is invisible to P1 grading because its commissioning migration flipped `status` but never touched
the adyen eligibility labels. The last item is not a sync bug: it is the Article 5 gap the
commissioning migration itself documented ("no canonical writer exists for machines.status on an
existing row — follow-up: create set_machine_status"). That follow-up was never filed.

## 2. Evidence (verified live 2026-09-08)

E1. `supabase_migrations.schema_migrations` rows with no file in `supabase/migrations/`
(name-substring match, exceptions prd053a and the prd118_i combined file excluded):

| version        | name                                          | statements      |
| -------------- | --------------------------------------------- | --------------- |
| 20260821094253 | prd117_reconcile_delivered_consumer_stock     | 1 / 8,511 chars |
| 20260821094348 | prd117_1_reconcile_skip_legacy_outcome_rows   | 1 / 6,357       |
| 20260824081149 | commission_iris_1070_single_door              | 1 / 2,549       |
| 20260907053215 | prd119b_t1_repair_remove_leg_shelf_lot_rpc_v2 | 1 / 4,508       |
| 20260907053259 | prd119b_t1_repair_remove_leg_shelf_lot_rpc_v3 | 1 / 4,497       |

Bodies are intact in `statements[]`. The v2/v3 pair is the tell: an RPC iterated through MCP
`apply_migration` three times, file written once.

E2. `git branch -vv`: `prd116-fe-dialogs` (1 commit ahead of origin/main: `0fe8f35 feat(prd-116h):
replace native window.prompt/confirm with in-app modals`, branch itself far behind main) and
`backup/pre-rebase-20260831` (8 commits, snapshot before the 08-31 rebase). Neither on origin.

E3. Dirty tree: `docs/prds/PRD-119b-goal-command.md` untracked; `docs/architecture/RPC_REGISTRY.md`,
`docs/prds/PRD-116-phase2-capacity-and-batch.md`, `docs/prds/PRD-116-refill-edge-case-hardening.md`,
`docs/prds/PRD-117-consolidated-remediation.md`, `src/app/(app)/app/pods/page.tsx`,
`src/app/(field)/field/config/machines/page.tsx` modified.

E4. `v_machine_eligibility_drift` → 1 row: `IRIS-1070-0000-O1`, `adyen_status='Switched off'`,
`adyen_inventory_in_store='Pending Setup'`, `sales_7d=20`. `machines.updated_at =
2026-08-24 08:12:08` = the minute `commission_iris_1070_single_door` ran. That migration set
`status='Active'`, `installation_date` only. Grep of migrations, edge functions, FE and n8n finds
NO automated writer of `adyen_status`; the only SQL writers are `repurpose_machine`
(→ 'Switched off', correct) and hand migrations (`mirror_lvlup_venue_group_machines`,
`merge_voxmcc_1009_duplicate_rows`). `machines.status` and the two adyen labels have no canonical
RPC; the FE `MachineEditPanel` writes them via direct table update.

E5. `git status` in the Cowork mount prints `unable to unlink .git/index.lock: Operation not
permitted` — the mounted copy is read-only for git. This loop runs in Claude Code / Terminal.

## 3. Decisions

D1. Reconstruct, never re-author. Each missing file = `array_to_string(statements, E'\n')` written
byte-for-byte under `<version>_<name>.sql`. A reconstructed file must hash-match the remote body
(`md5(array_to_string(statements,E'\n')) = md5(file)`), and the REPORT prints both hashes.

D2. `prd118_i_commitment_expose_breakdown` (20260831041717) is covered by the combined
`20260831041717_prd118_i_commitment_batch_grain_and_breakdown.sql`. Second permanent exception,
same class as prd053a. Record in MIGRATIONS_REGISTRY and in the drift-check task's exception list.

D3. `set_machine_status` becomes the ONLY writer of `machines.status`, `adyen_status`,
`adyen_inventory_in_store`, `installation_date`. Invariant enforced in the RPC and by a CHECK-style
trigger: `status='Active' AND repurposed_at IS NULL` ⇒ `adyen_status='Online today' AND
adyen_inventory_in_store='Live'`. `repurpose_machine` and `toggle_machine_refill` keep their own
scopes; `repurpose_machine` may call `set_machine_status` internally or stay as-is (Cody decides —
it is already canonical for its column set). Future `commission_*` migrations call the RPC, they
do not UPDATE `machines`.

D4. The IRIS-1070 label fix goes through the new RPC, not a bare UPDATE, so the first caller of
`set_machine_status` is the row that proved the need.

D5. `prd116-fe-dialogs`: cherry-pick `0fe8f35` onto main (rebase of a 117-file-behind branch is
not worth it), then delete the branch. `backup/pre-rebase-20260831`: prove every commit's patch-id
exists on main (`git cherry origin/main backup/pre-rebase-20260831` → all `-`), then delete; any
`+` line = push the branch as-is and stop.

D6. Dirty FE files (E3) are inspected before commit. If their diff is the prd116-fe-dialogs work,
they are dropped in favour of the cherry-pick; if independent, committed with their own message.
Docs are committed as-is with PRD-119b-goal-command.md.

D7. No stale-PRD closures in this loop. The seven-item decision list stays with CS for the weekly
session (PRD-107 in particular must be merged into PRD-119b, not closed).

## 4. Work

T1 — Migration parity (E1, D1, D2). Five files + one commit
`chore(migrations): reconstruct 5 prod-only migrations from schema_migrations.statements (PRD-121)`.
MIGRATIONS_REGISTRY updated with the five rows and the D2 exception.

T2 — Branch hygiene (E2, D5). Cherry-pick, patch-id proof, deletions, push. `boonz_git_cleanup.sh
--dry-run` output pasted in the REPORT before the real run.

T3 — Tree hygiene (E3, D6). Commit the PRD-119b goal command and the doc edits. Decide the two FE
files per D6.

T4 — `set_machine_status` (E4, D3). Dara designs signature + trigger; Cody reviews. SECURITY
DEFINER, role check (admin only), `p_reason text NOT NULL`, writes a `machine_status_events`
append-only row (machine_id, old/new status, old/new labels, reason, actor, via_rpc). Revoke
`authenticated` UPDATE on the four columns (or the whole table if RLS already routes writes through
RPCs — Cody decides). Rewire `MachineEditPanel` and any other FE direct writer to the RPC (`stax`).
`v_machine_eligibility_drift` gains an `age_days` column so the nightly guard can say "15 days".

T5 — IRIS-1070 (E4, D4). `SELECT set_machine_status('d5628a72-807a-4a64-9976-5d76139ae354',
'Active', 'Online today', 'Live', NULL, 'PRD-121: commissioning 08-24 set status only; labels
never flipped')`. Verify `v_machine_eligibility_drift` = 0 rows, `v_live_shelf_stock.
is_eligible_machine = true` for its 16 A lanes, and that the next `pick_machines_for_refill` dry
run lists it as a candidate.

T6 — Guard. Nightly assertion (same family as the PRD-119b nightlies): `v_machine_eligibility_drift`
must be empty; any row raises a monitoring_alert naming machine + labels + age. Second assertion:
`schema_migrations` rows ≥ 20260615 with no file — implemented as a CI step in the repo
(`scripts/check_migration_parity.sh`, reads remote via `supabase migration list` or MCP export),
red on any non-excepted miss. Wire it into the existing GitHub Actions / Vercel pre-deploy step.

T7 — Drift check re-run. `python3 boonz_build_refresh.py` from BOONZ BRAIN; expect
`untracked_migrations=[]`, `local_only=[]`, `prunable_count=0`, `dirty_count=0` (or the settings
exception only), prod-only=0, eligibility-drift=0 → "Environment GREEN".

## 5. Out of scope

Stale-PRD decisions (D7). `pod_address` for IRIS-1070 (still 'Dubai Harbor', CS has not supplied
the address). Lane depth verification for the 12 provisional IRIS-1070 capacities. The historical
pre-20260615 migration baseline (~950 rows, documented gap).

## 6. Acceptance

- All five hashes match; `git log origin/main` contains the reconstruction commit.
- `git branch -vv` shows no branch without an upstream except `main`.
- `v_machine_eligibility_drift` returns 0 rows; `set_machine_status` in RPC_REGISTRY as canonical
  writer for its four columns; FE has no direct write to them.
- Drift check verdict "Environment GREEN".
- REPORT ends with `## PRD-121 DONE`.
