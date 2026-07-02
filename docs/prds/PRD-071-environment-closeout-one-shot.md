# PRD-071: Environment Closeout, one shot

Status: Draft, approved direction by CS 2026-07-02. Run via `PRD-071-goal-command.md` in Claude Code (Fable 5).
Owner: CS. Mode: AUTO with hard gates (self-run Dara/Cody, SKIP-and-HIGHLIGHT on any gate failure, never wait mid-run).

## Why

PRD velocity (023 to 070 in ~3 weeks) left the board lying: PRDs live in prod still say Draft, 13 drafts are stale, ~10 branches carry unmerged docs commits, and the working checkout sits on a dead branch (feat/prd-065, 274 behind main, 83 WIP files). The environment itself is GREEN (main = origin/main = `11a1153`, 0 untracked migrations, 0 loss-risk branches). This PRD closes every open thread in one run so the Build Orchestrator reflects reality and work resumes from a clean main.

CS decisions (2026-07-02): WS-B apply with hard gates; WS-C resolve with defaults; WS-D batch-close stale drafts; WS-E salvage docs then delete branches.

## Non-goals

No engine changes. `engine_add_pod` and `engine_swap_pod` stay md5 byte-identical. `swaps_enabled` stays false. No new features. No FE work beyond none. Building any of the closed draft PRDs is out of scope; closing is a status action, reopenable.

## Workstreams

### WS-A: Branch reset (first, blocking)

1. In the repo checkout: inspect the 83 dirty files on `feat/prd-065-field-reconciliation`. Classify: (a) docs/skills/registries worth keeping, (b) generated junk (JSON exports, HTML reports), (c) already on main.
2. Commit keepers to a fresh branch `chore/prd-071-wip-salvage` cut from origin/main (NOT from prd-065), applying only the file contents that differ from main. Discard junk with a listed manifest in the execution log.
3. `git fetch origin && git checkout main && git pull --ff-only`. Delete local `feat/prd-065-field-reconciliation` with `-d` only (it is merged; if -d refuses, STOP and highlight).
4. Gate: `git status` clean on main, `main == origin/main`.

### WS-B: Auto-wire M2M pairing (the one real correctness gap)

`pair_internal_transfer_m2m` exists but nothing calls it. Until `push_plan_to_dispatch` invokes it, new internal-transfer legs can be created without `is_m2m`/`m2m_transfer_id` (the exact bug class PRD-070 fixed).

1. Dara: design the call site inside `push_plan_to_dispatch` (post-insert, same txn, idempotent; pairing failure must NOT fail the push, log and continue).
2. Cody: review against the Constitution (name the articles; this touches refill_dispatching, a protected entity).
3. Prove with BEGIN..ROLLBACK dry-run on a real plan date: legs get is_m2m/m2m_transfer_id set, WH delta = 0, non-transfer rows byte-identical.
4. Gates to apply: dry-run proof green, engines md5 unchanged (`6c3e853...c0c0`), swaps_enabled false, migration forward-only, writer idempotent (run twice, same state). Any gate fails: leave migration file authored, SKIP-and-HIGHLIGHT.
5. After apply: backfill any unpaired legs created since 2026-07-02, same proof pattern.

### WS-C: Data anomaly resolution (defaults approved by CS)

Each step: read state first, log before/after row images, BEGIN..ROLLBACK proof, then commit. All reversible.

1. MINDSHARE-1009 two stale Remove legs (2026-05-20, qty 3+5, internal_transfer, is_m2m=false, no dest): CANCEL both (unpairable by conservation rule). Record row snapshots in the log.
2. Transfer `1538f35f` (7 dest legs, returned=true + past-dated): route through `approve_m2m_transfer('1538f35f...')`; if the approve path rejects on returned/date, clear returned + re-date to plan-date current, then approve. WH delta must be 0.
3. Convert-path anomaly (dest legs created returned=true + past-dated, blocking pick list): fix at the APPROVE path (normalize returned/date on approval), not at convert. Guard, not rewrite; convert stays untouched.

### WS-D: Backlog truth sweep (board must stop lying)

1. For every PRD 023..070: fuse truth from execution logs, MIGRATIONS_REGISTRY, RPC_REGISTRY, CHANGELOG, origin/main commit log, and prod (read-only pg queries where a migration name is claimed). Update the status line at the top of each PRD doc to one of: Shipped (in prod + on main), Applied (in prod, git sync pending, name the missing commit), Draft, Closed.
2. Known mislabels to correct at minimum: 037, 042, 043, 044, 045, 046, 048, 054, 063, 068 (live in prod per logs/memory but board shows Draft/no status).
3. Batch-close stale drafts (untouched 14+ days, superseded or overtaken): 024, 025, 026, 027, 030, 031, 034, 035, 036, 039 and any others matching the rule EXCEPT 061, 062, 064, 066, 067, 069 (recent, stay open with a one-line verdict each). Closed line format: `Status: Closed 2026-07-02 (PRD-071 sweep). Reason: superseded by PRD-0NN / overtaken by X. Reopen by deleting this line.`
4. If any registry (MIGRATIONS_REGISTRY, RPC_REGISTRY, CHANGELOG) is missing an entry discovered during fusion, append it.

### WS-E: Git salvage and prune

1. For each unmerged-ahead branch (prd-020-packing-partial, prd-028-metrics-registry, prd-033-operator-flexibility, prd-047-v2, prd-049 x4, prd-050, prd-052-convert-m2m, prd-053-stitch-conservation, products-performance-table, wip/realign-2026-06-16): list the ahead commits; cherry-pick docs/log/registry commits onto a single branch `docs/prd-071-salvage` cut from main; for code commits, verify the change already exists on main or in prod (diff the function body / file), record the verdict.
2. HARD STOP rule: any code commit NOT reproducible on main or in prod gets the branch kept and highlighted; never delete it.
3. After salvage: merge `docs/prd-071-salvage` + `chore/prd-071-wip-salvage` to main via PR or ff, push, then delete fully-covered local+remote branches (`-d` locally; remote deletes listed for CS to confirm OR done if branch is proven fully covered; never force).
4. Run `boonz_git_cleanup.sh --apply` (from BOONZ BRAIN parent) as the final pass; paste its output into the log.

### WS-F: Close and verify

1. Regenerate the monitor: `python3 boonz_build_refresh.py` from BOONZ BRAIN. Banner must be GREEN; open/stale counts must drop to the true set (open = 061, 062, 064, 066, 067, 069 + anything WS-B/E highlighted).
2. Write `PRD-071-EXECUTION-LOG.md` as you go (every write, every proof, every skip).
3. Commit everything (docs + any migrations) to main, push. Git must be able to reconstruct prod (PRD-057 rule).
4. Final report: what shipped, what was skipped and why, the new open list.

## Acceptance

- HEAD on main == origin/main, working tree clean, prd-065 branch gone.
- `pair_internal_transfer_m2m` invoked automatically on push (or authored+highlighted if a gate failed), zero unpaired internal-transfer legs after backfill.
- MINDSHARE legs cancelled, `1538f35f` approved/pickable, approve-path guard live.
- Every PRD 023..070 has a truthful status line; stale drafts Closed; dashboard open count = real open work only.
- No branch deleted that carried unrecovered code. Engines byte-identical. swaps_enabled false.
- Monitor GREEN and regenerated; execution log complete; all committed and pushed.

## Rollback

WS-B: forward-only counter-migration reverting the call site (file held pattern). WS-C: row snapshots in the log allow manual restore. WS-D: status lines are text, revert via git. WS-E: salvage branches pushed before any delete; remote branches recoverable from reflog/origin for 90 days.
