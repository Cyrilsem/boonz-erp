# Parked migrations - AUTHORED, REVIEWED-PENDING, **NOT APPLIED**

⛔ Files here are **NOT** part of the applied migration set and **MUST NOT** be counted by RISK 104.

RISK 104 compares the DB's `supabase_migrations.schema_migrations` (rows `WHERE name LIKE '%prd110%'`)
against the **top-level** `supabase/migrations/*.sql` filename list. A file sitting unapplied in the
top-level directory makes the disk side read one higher than the DB forever, and every future leg then
burns a probe chasing a drift that is really just an unshipped file. `supabase db push` reads only the
top level, so a subdirectory is inert to the runner too.

⭐ **Park here, do not delete.** When the owning unit runs, `git mv` the file back up one level and
apply it with `/tmp/apply_mig.sh`, which registers the version in the same POST.

| file                                                        | owner | why parked                                                                                                     |
| ----------------------------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------- |
| `20260808160000_prd110_d37_ladder_prefer_own_stock_transfer_param.sql` | D-37  | Authored by the orphaned leg 153. Behaviour-neutral (nothing reads the column yet), but it is D-37 half 1 of 2 and LAW 8 preempted D-37 at leg 154. Its engine half does not exist. See S-293: D-37 must also absorb the ladder's inline name-only sentinel filter. |
