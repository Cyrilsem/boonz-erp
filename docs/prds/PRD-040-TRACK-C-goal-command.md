# Claude Code /goal — PRD-040 Track C (FE wiring, Stax)

Paste into Claude Code in `boonz-erp`. Builds the FE from the Track-C specs. Preview deploy + CS review before prod.

```
/goal Build PRD-040 Track C (FE wiring) per docs/prds/PRD-040-TRACK-C-FE-SPECS.md. Read that spec + PRD-034 + PRD-033 first. Supabase eizcexopcuoycuosittm. Stax owns FE; Cody verdicts any new RPC/edge fn; Dara only if a schema change is needed (avoid). No em dashes. Forward-only. No protected-table writes from FE (Article 3): all writes go through existing RPCs. Do NOT change engine_add_pod / engine_swap_pod / swaps_enabled.

C1 — VOX returns surface (PRD-034 Phase C):
- Add read-only get_vox_returns(p_date_from date, p_date_to date, p_venue text default null) returning the vox_return_log ledger (SECURITY INVOKER, STABLE, grants authenticated+service_role). Cody verdict (read-only helper, Article 15). Register in RPC_REGISTRY.
- FE: a VOX-returns view/table consuming it (no client re-derivation of the ledger).

C2 — operator-flexibility FE (PRD-033, RPCs already live):
- Wire reopen_stitched_rows, release_wh_quarantine, check_remove_without_replace (default BLOCK), convert_shelf into the refill/inventory FE. Surface check_remove_without_replace as a guard before REMOVE. No new RPCs; no direct table writes.

C3 — land feat/prd-033 work on main:
- Reconcile feat/prd-033-operator-flexibility (PRD-033, prd023i/j, Performance-tab FE) onto main. Rebase or cherry-pick the FE commits; resolve registry entries additively (PRD-033 + 023i/j were not carried in the earlier prod-sync). Do NOT regress anything already on main.

STEPS:
1. Branch off main: git switch -c feat/prd-040-track-c.
2. Build C1 (+ Cody verdict on get_vox_returns), C2, C3.
3. npm run build + lint must pass. Run any component tests.
4. Deploy to a Vercel PREVIEW; print the URL. STOP for CS review.
5. On CS "ship C": merge to main, push, deploy prod, update CHANGELOG/RPC_REGISTRY, write docs/prds/PRD-040-TRACK-C-EXECUTION-LOG.md.

HARD RULES
- swaps_enabled stays false (Track C does not touch it).
- engine_add_pod / engine_swap_pod byte-identical.
- FE never writes a protected table directly; only via live RPCs (Article 3).
- New RPC (get_vox_returns) must be Cody-verdicted before use.
- Preview + explicit CS sign-off before prod; nothing to prod silently.
```
