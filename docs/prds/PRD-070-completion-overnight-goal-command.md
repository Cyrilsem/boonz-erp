/goal PRD-070 completion + environment close, OVERNIGHT, MODE AUTO (self-run, do not wait on me). Repo boonz-erp. No em dashes. Full spec: docs/prds/PRD-070-m2m-approval-routes-to-destination-machine.md.

AUTO MODE: self-run Dara (design) and Cody (review, name articles) per writer; take their recommendations and continue; never stop to ask me; SKIP and HIGHLIGHT any piece that fails a gate; keep a running PRD-070-EXECUTION-LOG.md.

ALREADY DONE (verify present, do NOT redo): approve_m2m_transfer(p_transfer_id); wh_approved stamp col + index; is_m2m reject guards in receive_dispatch_line + wh_approve_remove_receipt; both migrations live+verified; PRD-070 on main (fc2eee9).

COMPLETE THESE. Each piece: Dara -> Cody -> migration FILE -> BEGIN..ROLLBACK dry-run -> apply only if green -> verify live -> commit -> push.

1. PAIRING INTEGRITY (D-2): make mark_internal_transfer AND convert_removes_to_m2m_transfer always set is_m2m=true + a shared m2m_transfer_id on BOTH legs at creation. Backfill existing is_m2m rows with NULL m2m_transfer_id into source+dest qty-matched groups (same product+expiry). Dry-run must show every is_m2m row ends with a non-null shared transfer_id, correct pairing, no row grouped twice.

2. DISPATCH VISIBILITY (D-3): ensure the dest Refill M2M leg surfaces in the destination machine dispatch/pick list (refill_plan_output / v_dispatch_pick_list); confirm the stitch/dispatch bridge does not drop M2M dest legs (known "stitch drops M2M" issue). If a view change is needed, Dara designs it, columns identical otherwise.

3. FE WIRING (Stax): wire PendingRemoveApprovalsPanel approve button to approve_m2m_transfer for is_m2m rows; keep wh_approve_remove_receipt for genuine machine->warehouse returns. FE typecheck/next build MUST pass before commit.

4. REGISTRIES: update RPC_REGISTRY.md (approve_m2m_transfer + new writers), MIGRATIONS_REGISTRY.md (new migrations), CHANGELOG.md. Mark PRD-070 D-2/D-3/FE APPLIED with dates.

HARD GATES (per piece): engine_add_pod + engine_swap_pod md5 byte-identical (prove); swaps_enabled stays false; every M2M dry-run asserts WAREHOUSE delta = 0 AND conservation (source pod out == dest pod in, same qty+expiry); idempotent (re-run = no-op); forward-only migrations; Cody PASS naming Articles 1,3,6,8,12 before apply. Do NOT disturb the completed Starbucks MC-2004 -> AMZ-1029 transfer or execute the live 1538f35f approval.

PUSH TO COMPLETION: for each GREEN piece (Cody PASS + dry-run proven + verified live), commit on feat/prd-070-completion and merge to main via a clean files-only 3-way (no unrelated src/doc drift, like the fc2eee9 push). FE pushes only after build passes. Never force-push, never delete a remote branch.

CLOSE + HYGIENE (last): git fetch origin; ff-sync local main to origin/main (git fetch origin main:main if not checked out); git branch -d every branch merged to origin/main (never -D, never the current branch); do NOT touch _HELD_ migrations or any uncommitted WIP; clear a size-0 stale .git/index.lock only if no git process is running. No parent-dir action needed (the monitor lives in BOONZ BRAIN and auto-refreshes).

STOP-AND-SKIP CONDITIONS (log under NEEDS CS, keep going): any WH-credit leak or conservation break in a dry-run; any non-idempotent result; any Cody REJECT; any FE build failure; any protected-entity destructive change; any ambiguity needing my judgment. Never apply or push a failing piece. Overnight: work through all four pieces plus close, then produce a final report - what applied+pushed, what SKIPPED and why, prod verification per piece, and the final clean git state.
