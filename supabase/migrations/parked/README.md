# Parked migrations - AUTHORED, REVIEWED-PENDING, **NOT APPLIED**

⛔ Files here are **NOT** part of the applied migration set and **MUST NOT** be counted by RISK 104.

RISK 104 compares the DB's `supabase_migrations.schema_migrations` (rows `WHERE name LIKE '%prd110%'`)
against the **top-level** `supabase/migrations/*.sql` filename list. A file sitting unapplied in the
top-level directory makes the disk side read one higher than the DB forever, and every future leg then
burns a probe chasing a drift that is really just an unshipped file. `supabase db push` reads only the
top level, so a subdirectory is inert to the runner too.

⭐ **Park here, do not delete.** When the owning unit runs, `git mv` the file back up one level and
apply it with `/tmp/apply_mig.sh`, which registers the version in the same POST.

| file     | owner | why parked |
| -------- | ----- | ---------- |
| _(none)_ | —     | —          |

⭐ **Empty is the correct steady state, and the directory still earns its keep.** Leg 155 `git mv`-d
`20260808160000_prd110_d37_ladder_prefer_own_stock_transfer_param.sql` back up and applied it as D-37
half 1; leg 156 removed the row that still claimed it was parked. ⛔ **A stale row here is worse than
no table** - it tells the next leg a file is unapplied when it is live, which is the mirror image of
the drift this directory exists to prevent.
