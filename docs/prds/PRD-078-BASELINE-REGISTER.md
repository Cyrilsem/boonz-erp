# Golden Baseline Register (PRD-078)

**golden_v1** · frozen 2026-07-07 · plan_date 2026-07-06 · run `9eb2d050-ba90-4a86-99d3-85449c6ecba2`
· engine_fingerprint `c22b57e6cb095c38858f1f73803c640d` · 21 plan rows · conservation total 21 (known-debt).

Fixture machines: AMZ-1038-3001-O1 (drift), NOOK-1019-0200-B1 (coworking),
VOXMCC-1005-0201-B0 (VOX), WPP-1002-4300-O1 (active intent), HUAWEI-2003-0000-B1 (niche).

**Re-baseline** is a deliberate, labelled action (golden_v2, ...) with a reviewer note,
only after an approved behavioural change. Never edit a frozen fixture (trigger enforces).

**Diff a candidate:** `SELECT refill_qa.diff_vs_golden('<candidate_run_id>');` — expects
`identical=true` for referee/verify PRDs, or ONLY the intended delta for guard PRDs.
Candidate capture requires the branch-data decision (MASTER-PARKING-LOT) to be resolved.
