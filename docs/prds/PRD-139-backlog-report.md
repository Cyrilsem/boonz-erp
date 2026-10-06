# PRD-139 Item 10: Warehouse Confirmations backlog report

Refreshed from prod on 2026-10-06 (PRD-139b), not the 5 October count. The 127
confirmations named in the original PRD-139 are now 64 -- the queue has been worked
down by the warehouse team and other sessions in the intervening time. This report
groups the current 64 by age bucket and source so the warehouse manager can clear the
oldest ones by hand; the Warehouse Confirmations panel itself now paginates 20 at a
time, sorted oldest first, with an amber badge over 48 hours and a red badge over 7
days (shipped in this same PRD-139b loop).

## By age bucket

| Bucket         | Count  |
| -------------- | ------ |
| Under 48 hours | 2      |
| 2 to 7 days    | 17     |
| 7 to 14 days   | 31     |
| Over 14 days   | 14     |
| **Total**      | **64** |

The single oldest line is about 48 days old. Most of the "over 14 days" group is in
the 14 to 20 day range; a handful go back further.

## By source

| Source              | Count | What it is                                                          |
| ------------------- | ----- | ------------------------------------------------------------------- |
| refill_return_ack   | 53    | A driver return the warehouse has not yet confirmed received.       |
| quarantine_batch    | 7     | A quarantined warehouse batch awaiting a manual adjust decision.    |
| reconcile           | 2     | A reconciliation line from an inventory count.                      |
| dispatch_return     | 1     | A returned dispatch line awaiting outcome (restock/waste/redeploy). |
| driver_expiry_check | 1     | A driver-flagged expiry check awaiting outcome.                     |

`refill_return_ack` and `quarantine_batch` are acknowledge-only (no outcome dropdown,
no disposal code, no split) -- clearing them is a single tap each in the panel.

## By machine (top 15, oldest line per machine)

| Machine                  | Lines | Oldest line (days) |
| ------------------------ | ----- | ------------------ |
| MC-2004-0100-O1          | 10    | 18.4               |
| AMZ-1038-3001-O1         | 8     | 18.4               |
| ACTIVATEMCC-1037-0000-L0 | 7     | 2.1                |
| (no machine on the line) | 7     | 47.9               |
| HUAWEI-2003-0000-B1      | 5     | 13.5               |
| VOXMCC-1011-0101-B0      | 5     | 10.4               |
| ACTIVATEMCC-2005-0000-W0 | 4     | 15.9               |
| VOXMCC-1005-0201-B0      | 4     | 10.4               |
| MPMCC-1054-0000-M0       | 3     | 2.1                |
| AMZ-1029-3003-O1         | 2     | 15.5               |
| VML-1004-0500-O1         | 2     | 11.5               |
| USH-1008-0000-W1         | 2     | 20.1               |
| OMDBB-1020-0P00-O1       | 1     | 0.8                |
| AMZ-1057-2403-O1         | 1     | 19.4               |
| NISSAN-0804-0000-L0      | 1     | 12.4               |

The 7 lines with no machine attached (the 48-day-old group) are worth checking first --
they are the oldest in the queue and will not show a machine name in the panel, so they
are easy to miss when scanning by machine.

## Suggested clearing order for the warehouse manager

1. The 7 machine-less lines (oldest, 48 days) -- open them in the panel, each shows the
   product and quantity even with no machine context.
2. The 14 lines over 14 days old, starting with MC-2004-0100-O1 and
   AMZ-1038-3001-O1 (10 and 8 lines respectively, both 18.4 days).
3. The 31 lines in the 7-14 day bucket.
4. The 17 lines in the 2-7 day bucket (not yet urgent, but will age into the red
   bucket within the week).

No live stock, pod inventory, or shelf capacity was changed to produce this report --
it is a read-only count refresh.
