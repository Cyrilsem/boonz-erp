# Road to cutover — decision brief for 17–19 Aug 2026

Prepared 2026-08-16, **corrected and re-verified 2026-08-19**. Subject: PRD-110 DR-1, per-cluster switch from the old refill engine (v19) to the new one (v3).

> **Correction (19 Aug):** the first version of this brief was dated 2026-08-16 and read the Day Close numbers as "today". The actual date was 19 Aug — the decision window closes today. The gate verdict is unchanged (all 10 clusters still refuse, still on v19). Day Close now reads: 61 returns pending manager receive (was 65), 3 rows awaiting review, 1 machine unreceived.

## Executive summary

1. **The accuracy numbers came in and v3 is currently losing.** On the three clusters where both engines have settled results, v3's forecasts are further from reality than v19's — in one case four times further.
2. **The safety gate agrees.** All 10 clusters are refused right now. Nothing can be flipped this week even if you wanted to; the system will say no.
3. **Six clusters have no v3 evidence at all**, so they are not "not yet ready" — they are unmeasurable until v3 actually plans machines inside them.
4. **The operational case for v3 is real and unchanged** — three sourcing data holes patched by hand in one week is a v1 design limit, not bad luck.
5. **Recommendation: WAIT on all 10 clusters.** Spend 17–19 Aug fixing the measurement, not flipping engines.

## Accuracy: v19 vs v3, per cluster

Read WMAPE as "how far off the forecast was, as a share of what actually sold". Lower is better. 0.36 means off by about a third; 1.66 means off by more than the entire volume.

| Cluster     | v19         | v3          | Verdict                                                 |
| ----------- | ----------- | ----------- | ------------------------------------------------------- |
| AMAZON      | 0.3628      | 0.6038      | v3 worse — nearly double the error                      |
| OHMYDESK    | 0.4974      | 0.6258      | v3 worse — closest of the three, still behind           |
| INDEPENDENT | 0.4243      | 1.6639      | v3 much worse — badly over-forecasting                  |
| NOVO        | not settled | 1.9140      | No comparison possible; v3's own number is poor         |
| VOX         | 1.1466      | not settled | v3 planned 160 series, none matured yet                 |
| VML         | not settled | not settled | Nothing to read                                         |
| ADDMIND     | 0.3564      | none        | v3 has never planned here                               |
| WPP         | 13.9520     | none        | v3 has never planned here; v19 number is junk (5 units) |
| GRIT        | none        | none        | No data on either side                                  |
| LVLUP       | none        | none        | No data on either side                                  |

**Important caveat (open item S-341):** the two columns are not measured on the same machines or the same velocity basis. On 2026-08-09, v3 was scored on 64 series across 4 machines using in-stock velocity; v19 on 48 series across 5 machines using 30-day velocity. Only 44 series overlap. So v3 is probably losing, but the size of the gap is not trustworthy. This should be fixed before the number is used to authorise anything.

## GO / WAIT per cluster

| Cluster                   | Call | Why                                                                        |
| ------------------------- | ---- | -------------------------------------------------------------------------- |
| AMAZON                    | WAIT | Measured and losing; the gate refuses it.                                  |
| OHMYDESK                  | WAIT | Measured and losing, though closest to parity.                             |
| INDEPENDENT               | WAIT | Measured and losing heavily.                                               |
| NOVO                      | WAIT | No v19 baseline settled, so nothing to beat.                               |
| VOX                       | WAIT | v3 rows exist but have not matured; biggest cluster, worst place to guess. |
| VML                       | WAIT | Neither side settled.                                                      |
| ADDMIND, GRIT, LVLUP, WPP | WAIT | v3 has never planned a machine here; refusal is permanent until it does.   |

## What the flip requires of you

There is no button. The cutover is SQL only — the front-end for it is built but sitting undeployed (local `main` is 23 commits ahead of origin). Per cluster:

```sql
-- Flip one cluster (evidence-gated; will refuse today)
SELECT public.flip_cluster_to_v3_v3('AMAZON', 'reason, at least ten characters');

-- Reverse one cluster (never gated, always works)
SELECT public.revert_cluster_to_v19_v3('AMAZON', 'reason, at least ten characters');

-- Check the gate before trying
SELECT * FROM public.v_cutover_readiness_v3 ORDER BY cluster_key;
```

You must be signed in as `operator_admin`. Both refusals and successes are written to `engine_cutover_audit_v3`, so a blocked attempt leaves a record.

**Warning about a false message (open item S-342):** if a flip ever does succeed, the success text tells you the nightly builder will refuse to build. That sentence is out of date — it was true before DR-1b shipped on 08-08 and is false now. Ignore it. Reverting because of it would undo a good cutover for no reason.

## Operational evidence for v3

Three venue-sourcing holes were patched by hand in eight days: 7Up standing in for Coke on VOX machines (08-08, 87 mappings across 11 machines), Red Bull venue entries minted (08-14), and all chocolate flipped to venue-sourced on VOX/ACTIVATE/IFLY/MP after a Central-warehouse Snickers reached a VOX machine (08-15, 25 mappings across 10 machines). Each was a person noticing something the system could not represent: v19 loses per-product sourcing on mixed shelves, v3 models sourcing natively. That is the strongest argument for cutover and it is unaffected by the accuracy problem.

PRDs 111–115 all shipped this month and were built engine-agnostic — pack-ahead date toggle, driver substitution and Day Close, in-machine moves and the expired-stock guard, the driver visit checklist, and mid-pack plan edit safety. All of them sit downstream of whoever authors the plan, so every one of them carries over to v3 unchanged. Nothing has to be rebuilt.

## Open items arguing caution

Five golden fixtures are red: 14, 16, 42, 46, 74. **None of them blocks the flip.** 42 and 46 are unchanged from before the branch; 14 and 16 broke because live fleet stock moved under fixtures that bind to real state. Fixture 74 is the DR-1 cutover-readiness fixture and it went from 5 failures to 8 — but only because the calendar moved past expectations baked into it, so it now expects verdict strings that reality has overtaken. Worth knowing: 74 being red means the cutover's own automated test is not currently a working guard, so the live readiness view is the only source of truth this week.

Day Close is broadly clean. Today (08-16) passes four of five checks. The one standing failure is **65 returns pending manager receive**, identical on 08-13, 08-14, 08-15 and 08-16 — a backlog nobody is working, not a weekend spike. Weekend unreceived machines (2, then 4, then 1) have all cleared. One `needs_review` row appeared Saturday and is gone. Two real day-close events from 08-10 remain unacknowledged (one stock-unverified, one substitution); the other 85 events in the table are dated 2030 and are test fixtures.

## Rollback

Reversal is per cluster and deliberately ungated. `revert_cluster_to_v19_v3(cluster, reason)` needs only the operator_admin role and a ten-character reason — it never consults the accuracy view, because a rollback that can be blocked by the same gate that blocks the forward path is a trap, not a safety valve. It sets the cluster back to v19, clears the flip timestamp, reason and evidence snapshot, and writes an audit row. In-flight work is safe: the nightly builder reads cluster authority at build time, and DR-1b scopes the old engine's delete-and-replan to non-authoritative machines only, so the next nightly build simply re-plans that cluster with v19. Plans already pushed to dispatch are untouched — the cutover only decides who writes tomorrow's draft, never who packs today's.
