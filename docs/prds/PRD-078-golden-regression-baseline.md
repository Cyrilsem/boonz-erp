# PRD-078: Golden regression baseline

Status: DRAFT 2026-07-07. NET-NEW (no prior art). Wave 0 / 0a.3. Depends PRD-076 (store+diff) + PRD-077 (conservation).
Owner: CS. Mode: AUTO with hard gates. Dara designs the fixture store, Cody reviews, Stax wires.

## Why

The diff harness (PRD-076) needs a trusted, frozen reference. Production inputs change hourly, so "before/after" drifts unless inputs are frozen. This PRD captures an immutable **golden baseline** — engine output + conservation verdict for a representative machine set on frozen inputs — that every later wave diffs against to prove it changed only what it intended. Versioned, so we re-baseline deliberately after an approved behavioural change.

## Design (Dara designs, Cody reviews, Stax wires)

1. **Representative set** (documented rationale each): 1 AMZ (drift-prone A01/A09), 1 coworking, 1 VOX/cinema, 1 machine with an active strategic intent, 1 niche-SKU machine (HUAWEI / SF Pancake `fad6df6d-ac14-487a-be17-4210fb2d3c70`).
2. **`refill_qa.input_fixture(fixture_id, plan_date, machine_ids uuid[], frozen_at, input_hash, schema_version, payload jsonb)`** — freeze input slices for chosen NON-Saturday plan_dates; immutable once frozen.
3. **Capture `golden_v1`** via `capture_run` on the fixture + store the PRD-077 conservation verdict (records current known-debt). Version label.
4. **`refill_qa.diff_vs_golden(candidate_run)`** = `diff_runs(golden_v1, candidate)` scoped to the fixture machines. Re-baseline requires an explicit labelled action + reviewer note.

## Gates

- Immutable once frozen (trigger blocks UPDATE on a frozen fixture). Records `schema_version`; a schema change forces a conscious re-baseline.
- Engines md5 byte-identical. Additive data only; Cody signs.
- Sample cross-checked once against a full-fleet capture before locking (representativeness).

## T-tests

- T1 re-run engine on frozen fixture ⇒ `diff_vs_golden` identical (or flag `deterministic=false` per known Cause-G non-determinism → tolerance mode, feeds a future hardening PRD).
- T2 perturb one fixture input ⇒ only affected rows differ.
- T3 conservation verdict stored with golden.
- T4 attempt to mutate a frozen fixture ⇒ rejected.

## CLOSE

Baseline register doc (machines + rationale + known-debt) in `_programs/`; PRD-078 status SHIPPED + EXECUTION-LOG; commit + push. **Wave 0a (referee) complete** ⇒ unlocks PRD-079..085.
