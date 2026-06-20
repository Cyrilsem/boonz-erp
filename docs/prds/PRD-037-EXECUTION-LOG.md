# PRD-037 Execution Log — Refill v4 Swap Engine (Phase 0 + Phase 1)

**Applied:** 2026-06-20, by CS authorization (Cowork session), Supabase project eizcexopcuoycuosittm.
**Status:** Phase 0 + Phase 1 APPLIED to prod. `swaps_enabled` stays `false` (engine_swap_pod Pass-3 is a no-op until Phase 3 enable). engine_add_pod FROZEN and untouched.

## What was applied

### Phase 0 — migration `prd037_p0_coexistence_rules_brand_owner`

- `boonz_products.brand_owner` column added; backfilled to 'The Coca-Cola Company' for the TCCC portfolio. Live count: **6 products tagged**.
- `coexistence_rules` table created (RLS: select true, no insert/update/delete for authenticated) + 2 indexes. Seeded **12 rules**: Rule 1 (TCCC venue exclusion ADDMIND/VOX), Groups 2/3/4/7 (max-1-per-brand: Coca Cola, Pepsi, Almarai Juice, Loacker), Groups 5/6 (Evian Sparkling vs Perrier; Krambals vs Zigi), Group 1 (Soft Drinks Mix, name-keyed, inert until that SKU exists).

### Phase 1 — migration `prd037_p1_engine_swap_pod_v12`

- `_coexistence_blocks(uuid,uuid)` and `_travel_scope_blocks(uuid,uuid)` created (read-only STABLE SECURITY DEFINER).
- `engine_swap_pod` v11 -> v12: Pass-3 rewritten to the value model V(P,S,M)=margin x min(velocity x D, cap); SWAP only when best eligible candidate beats KEEP by theta=0.15; rate-limited (<= per-machine cap, fleet <= 10, 14-day cooldown). Includes the 2026-06-20 Pass-3 intra-cycle swap-in dedup guard.

## Live verification (post-apply)

- coexistence_rules rows: 12. brand_owner TCCC tagged: 6.
- \_coexistence_blocks, \_travel_scope_blocks: present.
- engine_swap_pod engine_version: `v12_value_model`. Dedup clause present in 2 passes (dead-tag + Pass-3).
- engine_add_pod engine_version: `v18_relative_score_band_f1_per_machine` (UNTOUCHED, T12 holds).
- refill_settings.swaps_enabled: `false`.

## Test table (re-scoped, rolled-back replays on live data, 2026-06-20)

| #   | Test                                                                 | Result             |
| --- | -------------------------------------------------------------------- | ------------------ |
| T1  | TCCC blocked @ADDMIND (clean allowed)                                | PASS               |
| T2  | TCCC blocked @VOX                                                    | PASS               |
| T3  | Sparkling dup (Perrier -> Evian blocked)                             | PASS               |
| T4  | Brand dup (Coca Cola x2 blocked)                                     | PASS               |
| T5  | Theta gate -> KEEP (USH-1008 V_cand 9.11 < 10.09 x1.15)              | PASS               |
| T6  | No-substitute -> KEEP, not stranded (constructed empty pool)         | PASS               |
| T7  | Kill switch (swaps_enabled=false -> 0 Pass-3)                        | PASS               |
| T10 | 14-day removal cooldown set                                          | PASS               |
| T11 | Rate limits (<=2/machine, fleet 10)                                  | PASS (cap in code) |
| T12 | ADD regression (engine_add_pod untouched)                            | PASS (structural)  |
| T13 | ADDMIND-1007 worked example (re-scoped Phase-1 guardrail invariants) | PASS               |

T13 re-scope note: the original T13 asserted literal swap-in products (YoPRO/Zigi) and an Activia redeploy tag. Redeploy is WS-4 (Phase 2), and the value model selects by real margin x velocity (it proposes Be-kind Bar / McVities on ADDMIND-1007, not the illustrative SKUs; YoPRO is eligible but ranks last at V=0). Phase-1 T13 now asserts the guardrail invariants (coexistence-clean, non-TCCC, in-stock, non-duplicate SWAP with V >= keep x1.15). Literal products + redeploy moved to Phase-2 T13b / T9.

## Cody

- Phase 0 schema: Approve (Articles 2/3/12/14).
- v12 body: Approve (Articles 1/4/6/8).
- Pass-3 dedup guard delta: Approve (Articles 1/4/8/12).

## Open follow-ups

1. Phase 2 (PRD-039): broad candidate universe, candidate-specific capacity matrix, top-N unique assignment, homogenisation guard. Gated /goal authored.
2. Phase 3: flip swaps_enabled true after N supervised cycles.
3. product_family_id backfill (Rule 2 family-keyed); true gross-profit margin; 70/30 = PRD-038.
