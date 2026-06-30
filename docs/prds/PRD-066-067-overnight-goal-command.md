# Overnight /goal - lifecycle + data-integrity batch (PRD-066, 067, 034, 061, git sync)

Paste into Claude Code in `boonz-erp`. Under 4000 chars. STOPs for CS before destructive steps.

```
/goal OVERNIGHT BATCH - Boonz lifecycle + data-integrity cleanup. Supabase eizcexopcuoycuosittm. Run to completion; on any gap SKIP it and record it in a final INCOMPLETE log, never force. Canonical RPCs only. Cody verdict required for every step touching machines / pod_inventory / warehouse_inventory / refill_dispatching (Articles 1,3,12). Migration FILE before any apply. STOP for CS before each DELETE, machine status flip, or pod write-off (list them and wait for my go). Idempotent throughout: a step already done is a no-op. No em dashes.

Execute in order:

1. PRD-066 (docs/prds/PRD-066-lifecycle-returns-pod-reconciliation.md). Reconcile the stale returns queue. Decline via decline_dispatch_return (NO WH credit) the named wrong/junk rows: Eviron MPMCC-1054, Santiveri ALJLT-1015 x2, NRJ Mindshare-1009, Sun Blast Wavemaker-1006, plus every row pending >120h with driver_confirmed_qty=0. Re-add Vitamin Well (Antioxidant, Hydrate, Zero Peach) to USH-1008-0000-W1 pod via the canonical pod writer because the stock was never physically pulled; assert pod delta = declined REMOVE qty. Complete the AMZ M2M and MC-2004->Amazon receives via receive_dispatch_line ONLY if the source REMOVE is real and unreceived, else decline. SCOPE GUARD: never touch a row younger than 48h; print the candidate set + per-row decision before any write.

2. PRD-067 (docs/prds/PRD-067-dataintegrity-dup-product-phantom-machines.md). (a) Sour Cream: KEEP 4edc4fbb (24 maps / 27 units), rename it to "Hunter Ridge - Sour Cream & Onion" (confirm direction with me), then DELETE the empty 285479a7 after a zero-reference scan. (b) JET: delete the 76 orphan product_mapping rows on the already-Inactive JET-2001-3000-O1 so it stops showing as a 2nd Jet. (c) WH2-2001-3000-O1 phantom: write off its 57 active pod rows (102 expired units) via backfill_archive_pod_inventory_row with NO WH credit, delete its 226 product_mapping rows, flip status Warehouse->Inactive. STOP for me before the deletes / write-off / status flip.

3. PRD-034 (docs/prds/PRD-034-vox-return-no-wh-credit.md). Apply the venue_team guard in receive_dispatch_line so VOX-supplied returns never credit Boonz warehouse. This is the recurrence fix for the returns-queue mess.

4. PRD-068 (docs/prds/PRD-068-refill-log-integrity-post-confirm-conservation.md). Reconcile the 5 live conservation violations from check_pod_conservation('2026-06-30') + recent stitch_leakage to driver-confirmed truth; zero filled_quantity on the 8 rows where pack_outcome='not_filled' AND filled_quantity>0; purge the 9 test rows dated >= 2099; wire the post-confirm conservation re-assert on the confirm/edit RPCs; schedule the daily conservation monitor. After the run check_pod_conservation must return zero rows for 2026-06-24..30.

5. PRD-036 backend only (docs/prds/PRD-036-pickable-stock-and-field-batch-capture.md). Bind every Refill/Add dispatch line to a FEFO warehouse batch (populate from_wh_inventory_id) so pickup qty + expiry stop showing 0; 647 of 1719 lines are currently unbound. Backend FEFO-bind ONLY - the FE field-capture stays a separate supervised build, not this run.

6. Close the remaining PRD-061 INCOMPLETE rows (idempotent); skip+log anything still unresolved (Amazon-0735 unknown items).

7. GIT SYNC to main: commit the already-applied-but-uncommitted work - PRD-062 (Hunter Hot N Sweet merge), the decline_dispatch_return RPC - plus the new 066 / 067 / 034 migrations and docs. Forward-only. Push to main.

Deliver: per-step row counts + conservation asserts + Cody verdicts; the explicit list of items awaiting my green light (deletes / status flips / write-offs); and the final INCOMPLETE-tasks log.
```

PRDs: 066, 067, 034 in `boonz-erp/docs/prds/`. The two STOP gates are the PRD-067 deletes/flip and the Sour Cream rename direction.

```

```
