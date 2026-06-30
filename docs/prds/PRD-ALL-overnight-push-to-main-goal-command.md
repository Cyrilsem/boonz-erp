# MASTER overnight /goal - ship every active + new PRD to main by morning

Paste into Claude Code in `boonz-erp`. CS pre-authorized the destructive steps (2026-06-30). Supabase eizcexopcuoycuosittm.

## PRD state manifest (ground truth for the run)

| PRD                                               | What                                                 | State now                                                                    | Action this run                          |
| ------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------------------- |
| 049                                               | packing/returns FE                                   | on main (d25c84b)                                                            | none                                     |
| 053 backend                                       | stitch conservation v27/v28                          | applied; files in tree                                                       | commit to main                           |
| 053 driver-add FE                                 | flagged additions wire                               | branch feat/prd-053-driver-add-flag                                          | merge IF builds+QA clean, else log       |
| 040 / 042 / 043 / 044-047 / 058 / 059 / 063 / 065 | swap, picker, packing, priority, expiry, field-recon | applied to prod; migration FILES present in supabase/migrations; NOT on main | commit + merge to main (do NOT re-apply) |
| 062                                               | Hunter Hot N Sweet merge+delete                      | applied via MCP, NO file                                                     | generate file from live prod, commit     |
| decline_dispatch_return                           | force-remove VOX returns no WH credit                | applied via MCP (decline_dispatch_return_writer), NO file                    | generate file from live prod, commit     |
| 034                                               | VOX venue_team WH-credit guard                       | authored, NOT applied                                                        | apply + commit                           |
| 036 backend                                       | FEFO bind at pickup (from_wh_inventory_id)           | written, NOT built                                                           | apply backend only + commit              |
| 061                                               | Jojo edits reconciliation                            | ran, INCOMPLETE rows                                                         | close + log leftovers                    |
| 066                                               | returns queue + pod reconciliation                   | new                                                                          | apply + commit                           |
| 067                                               | dup product + phantom machines                       | new, PRE-AUTHORIZED deletes                                                  | apply FULL + commit                      |
| 068                                               | log integrity + post-confirm re-assert               | new, PRE-AUTHORIZED RPC change                                               | apply + commit                           |

```
/goal MASTER OVERNIGHT - bring main fully in line with prod and ship every active + new PRD by morning. Repo boonz-erp, Supabase eizcexopcuoycuosittm. CS pre-authorized every destructive step in PRD-067 + PRD-068. Run to completion; on any gap or merge conflict you cannot safely auto-resolve, SKIP it, leave the work untouched, log it in a final INCOMPLETE list - never force-resolve, never lose work. Canonical RPCs only. Cody verdict required for any backend change touching protected entities (Art 1,3,12,16). Idempotent: NEVER re-apply a migration already in prod history; a done step is a no-op. No em dashes. Read docs/prds/PRD-ALL-overnight-push-to-main-goal-command.md manifest first.

PHASE 0 INVENTORY (read-only, print plan before any write)
- Diff prod migration history vs files in supabase/migrations vs main. List every migration applied-to-prod-but-not-on-main and every prod object with NO file.
- Generate forward migration FILES from the LIVE prod definitions (do NOT re-run) for the two fileless MCP-applied objects: PRD-062 Hunter Hot N Sweet merge, and decline_dispatch_return (decline_dispatch_return_writer).

PHASE 1 APPLY NEW PRDs (Cody-reviewed, idempotent, conservation-asserted, skip+log gaps), in order:
- PRD-066: reconcile stale returns queue + re-add Vitamin Well to USH-1008; SCOPE GUARD never touch rows <48h.
- PRD-067 FULL, PRE-AUTHORIZED: write off + inactivate phantom WH2-2001-3000-O1 (57 rows/102 expired units, NO WH credit), delete its 226 orphan mappings, delete the 76 orphan mappings on Inactive JET-2001-3000-O1, rename 4edc4fbb to "Hunter Ridge - Sour Cream & Onion" then delete empty 285479a7 after a zero-ref scan.
- PRD-034: venue_team guard in receive_dispatch_line.
- PRD-068 incl the post-confirm conservation re-assert RPC, PRE-AUTHORIZED: reconcile the 5 live violations + recent stitch_leakage to driver-confirmed truth, zero filled_quantity on the 8 not_filled rows, purge the 9 rows dated >=2099, wire the re-assert on confirm/edit RPCs, schedule the daily conservation monitor.
- PRD-036 backend ONLY: FEFO-bind from_wh_inventory_id on the 647 unbound Refill/Add lines; FE field-capture EXCLUDED.
- Close PRD-061 INCOMPLETE rows; skip+log unresolved (Amazon-0735 unknowns).
Each PRD doc is docs/prds/PRD-0NN-*.md. After Phase 1, check_pod_conservation must return zero for 2026-06-24..30.

PHASE 2 CONSOLIDATE TO MAIN
- Commit the legit working-tree changes (skills, docs, PRD logs, migration files) on their branch. FLAG + EXCLUDE anything unintended, esp the large "BOONZ DAILY SALES ENHANCED *.json" data files, unless clearly part of a PRD.
- Merge into main every branch with live-but-unmerged work: feat/prd-065-field-reconciliation, feat/prd-052 (PRD-059), and the new work. Merge feat/prd-053-driver-add-flag ONLY if it builds clean + QA passes, else leave + log.
- Ensure main holds a committed migration file for EVERY prod object (incl the generated 062 + decline files and all of 034/036/066/067/068). Push main.

PHASE 3 VERIFY + REPORT
- Assert main migration set == prod history (zero drift); list any remaining drift.
- Deliver: Phase 0 plan, per-PRD applied/committed/merged status, Cody verdicts, the check_pod_conservation re-check, the generated-files list, and the final INCOMPLETE log.
```

After it runs, paste me the Phase 3 report. The only things that should appear in the INCOMPLETE log are merge conflicts it refused to force and any PRD-061 unknowns.
