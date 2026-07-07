# PRD-078 goal command

GOAL: Execute PRD-078 (docs/prds/PRD-078-golden-regression-baseline.md) end to end, AUTO mode. Self-run Dara/Cody/Stax. Keep PRD-078-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076 + PRD-077.

HARD GATES: engines md5 byte-identical. Additive data only. Fixtures immutable once frozen (trigger blocks UPDATE). Record schema_version. BEGIN..ROLLBACK for DDL; forward-only. Cody signs.

WS-1 Pick representative machines (document rationale): 1 AMZ (A01/A09 drift), 1 coworking, 1 VOX/cinema, 1 with active strategic intent, 1 niche-SKU (HUAWEI / SF Pancake fad6df6d-ac14-487a-be17-4210fb2d3c70). Write baseline register.

WS-2 (Dara) input_fixture(fixture_id,plan_date,machine_ids,frozen_at,input_hash,schema_version,payload): freeze input slices for NON-Saturday plan_dates; immutable.

WS-3 Capture golden_v1 via capture_run on the fixture + store PRD-077 conservation verdict. Version it.

WS-4 diff_vs_golden(candidate)=diff_runs(golden_v1,candidate) scoped to fixture machines. Re-baseline = explicit labelled action + note.

T-TESTS: T1 re-run on frozen fixture => identical (or flag deterministic=false => tolerance mode). T2 perturb one input => only affected rows differ. T3 conservation verdict stored. T4 mutate frozen fixture => rejected.

CLOSE: baseline register in _programs/; RPC_REGISTRY + CHANGELOG; PRD-078 SHIPPED + EXECUTION-LOG; commit + push, main==origin/main. Declares Wave 0a COMPLETE. ON BLOCKER: append PARKING_LOT.md and continue (tolerance mode if non-deterministic).
