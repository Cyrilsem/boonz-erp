# Wave 0 — Reconciliation vs Existing PRDs

**Date:** 2026-07-07 · **Purpose:** map the proposed "Wave 0 / trust-the-data" foundation against PRDs already in `docs/prds/` before creating any new PRD, so we don't re-plan shipped work.
**Method:** verified each item against the on-disk PRD status lines (not assumptions). Highest existing PRD = **075**; next free number = **076**.

## Verdict summary

- **5 of 8 functional Wave-0 items are already shipped** under prior PRDs.
- **The only net-new work is the referee/test-harness layer** (shadow-diff + golden baseline + a reusable conservation _gate_), which does not exist in the repo.
- **2 items need a quick verify** (possible partial): orphan engine retirement, and a pre-pack _blocking_ guard vs the existing _monitor_.

## Assigned PRD numbers (formalized per CS — full Wave 0)

Wave 0 is now written into `docs/prds/` as **PRD-076 → PRD-085** (spec + `-goal-command` each), run by `WAVE0-APPLY-ALL-goal-command.md`. The 5 shipped items are authored as **VERIFY + referee-regression + residual-closure**, not re-implementation — each carries a prior-art Status banner.

| New PRD     | Wave 0 item                      | Nature               | Prior art (respect Status banner)           |
| ----------- | -------------------------------- | -------------------- | ------------------------------------------- |
| **PRD-076** | W0a.1 shadow-diff harness        | NET-NEW              | none                                        |
| **PRD-077** | W0a.2 conservation merge gate    | NEW gate             | PRD-053, PRD-068 (guards shipped)           |
| **PRD-078** | W0a.3 golden baseline            | NET-NEW              | none                                        |
| **PRD-079** | W0b.1 availability + held-state  | VERIFY + add         | PRD-045, PRD-036 (shipped)                  |
| **PRD-080** | W0b.2 FEFO + reservation         | VERIFY + residual    | PRD-036, PRD-050 (shipped); PRD-072 residue |
| **PRD-081** | W0b.3 enforce pack RPC only      | VERIFY + guard       | PRD-028, PRD-068 (shipped)                  |
| **PRD-082** | W0b.4 planned vs filled qty      | VERIFY + residual    | PRD-044 (shipped)                           |
| **PRD-083** | W0c.1 retire duplicate engine    | EXTEND               | PRD-074 (partial)                           |
| **PRD-084** | W0c.2 pre-pack drift guard       | EXTEND monitor→block | PRD-057, PRD-067                            |
| **PRD-085** | W0c.3 finalize preserve-approved | VERIFY only          | PRD-025 (shipped/closed)                    |

## Reconciliation table (detail)

| Wave 0 item                                         | Intent                                                | Existing PRD(s)                                                                                                                       | On-disk status                                  | Verdict                                                                         |
| --------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------- |
| **W0a.1** shadow-diff harness                       | Run engine in isolation, diff plan output vs baseline | — none —                                                                                                                              | —                                               | **NEW — gap**                                                                   |
| **W0a.2** conservation _gate_ (reusable, pre-merge) | Pass/fail referee on pod↔WH conservation              | PRD-053 (stitch conservation, shipped 06-24), PRD-068 (post-confirm conservation guards, shipped 07-01)                               | Guards live, but not a reusable diff/merge gate | **PARTIAL — gate is new**                                                       |
| **W0a.3** golden baseline                           | Frozen regression reference                           | — none —                                                                                                                              | —                                               | **NEW — gap**                                                                   |
| **W0b.1** availability gate truth                   | `v_wh_pickable`/availability reflects reality         | PRD-045 (shipped 06-21), PRD-036 (shipped 07-01), PRD-017 (closed 07-02)                                                              | Shipped                                         | **DONE**                                                                        |
| **W0b.2** FEFO + reservation                        | Bind + reserve batch at approve; no phantom/oversub   | PRD-036 (FEFO bind, shipped), PRD-050 (pickqty→plan, shipped 06-23), PRD-018 (reservation design), PRD-072 (residue sweep, **draft**) | Mostly shipped; residue in PRD-072              | **DONE** (track PRD-072 residue)                                                |
| **W0b.3** block FE pack bypass                      | Warehouse moves only via pack RPC (BUG-006)           | PRD-028 (shipped 06-12), PRD-068 (shipped 07-01)                                                                                      | Shipped; `from_wh` guard live                   | **DONE**                                                                        |
| **W0b.4** planned vs filled qty                     | Don't let pack overwrite planned qty                  | PRD-044 (shipped 06-21), PRD-030 (closed 07-02 → superseded by 044)                                                                   | Shipped                                         | **DONE**                                                                        |
| **W0c.1** retire duplicate engine                   | One canonical engine; remove Family B                 | PRD-074 (priority SSOT, shipped 07-04); `auto_generate_refill_plan` deprecated                                                        | Partial — legacy picker deprecated              | **VERIFY** — confirm `orchestrate_refill_plan`/`propose_*` orphan family status |
| **W0c.2** pre-pack drift guard                      | Block dispatch lines where planned SKU ≠ live WEIMI   | PRD-057 (drift _monitor_, shipped 06-25), PRD-067 (phantom machines)                                                                  | Monitor exists; no pre-pack _block_             | **POSSIBLE GAP** — monitor ≠ blocking guard                                     |
| **W0c.3** finalize un-approve                       | Finalize must not reset approved→draft                | PRD-025 (closed 07-02)                                                                                                                | Shipped via Refill v2 finalize subset-aware     | **DONE**                                                                        |

## Recommendation (minimal, non-duplicative)

1. **Build the referee only** — the genuinely new, high-leverage gap: `PRD-076` shadow-diff harness, `PRD-077` conservation gate (reusable), `PRD-078` golden baseline. Follow repo convention (`PRD-0NN-<slug>.md` + `PRD-0NN-goal-command.md` + `PRD-0NN-EXECUTION-LOG.md`).
2. **Verify, don't rebuild** W0c.1 (orphan engine family) and W0c.2 (pre-pack blocking guard) — a 20-minute read of prod + PRD-057/074 decides whether either needs a small follow-up PRD.
3. **Drop** W0b.1–b.4 and W0c.3 from the Wave 0 plan — already shipped (PRD-045/036/050/028/068/044/025).

## What the earlier autonomous loop hit

The `WAVE0-LOOP` executor correctly parked all 10 items because the Wave 0 PRD files were authored into a Cowork scratch/output folder, **not** into `docs/prds/`, so the loop (which reads the repo) found no inputs. Root cause = file placement, plus the overlap documented above. This doc is the correction.
