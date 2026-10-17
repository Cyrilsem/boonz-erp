# PRD-138 WS-C: drift routine prompt changes (for CS to paste)

The PRD-141c loop could not edit the scheduled routine prompt itself
(`~/Documents/Claude/Scheduled/boonz-build-drift-check/SKILL.md`): the Claude Code auto-mode
classifier refuses edits to another agent's instructions. The database side of WS-C.1
(`drift_reason` values on `v_machine_eligibility_drift`) is live. Paste the three blocks below
into the routine's SKILL.md to finish WS-C.

## 1. STEP 2b, insert before "List every non-excepted remote migration with NO matching file"

SAME-VERSION FALLBACK (PRD-138 WS-C): if no filename contains the name, a file whose 14-digit
version prefix equals the row's version counts as a match (the body was recorded under a different
name); report these as "matched by version". DOCUMENTED EXCEPTION (PRD-138 WS-C): rows with version
from 20260912000000 to 20260915235959 are the 2026-09-12 to 2026-09-15 consolidation window (63
known-good rows recorded under consolidated file names); do not flag them, report only their count.

## 2. Replace STEP 2c with

STEP 2c - LABEL-BLIND WATCH: SELECT official_name, adyen_status, adyen_inventory_in_store, sales_7d,
drift_reason FROM v_machine_eligibility_drift. Expect zero rows. Read drift_reason, it names the true
cause:

- 'in_repurpose_grace': a repurposed machine still inside its grace window that has not yet reached
  repurpose_min_sales. NOT label drift and NOT RED; report it as AMBER with the machine and its
  repurposed_at, and do not tell anyone to fix a label.
- 'label_not_live': a selling machine whose Adyen labels are not Online today / Live. Since PRD-141
  item 14 the machine is still graded, but the label is wrong: RED, name the machine and the lying
  label; the fix is the Adyen sync WRITER, not the row.
- 'selling but invisible to grading': a selling, labelled-live machine still missing from
  v_shelf_sales_identity: RED, unexplained, investigate.

In STEP 3 change "AND eligibility-drift rows are all 0" to "AND eligibility-drift rows other than
'in_repurpose_grace' are all 0".

## 3. Append STEP 4

STEP 4 - STALE LOCK SWEEP: this run's own git status can leave boonz-erp/.git/index.lock behind and
this environment cannot delete files. As the last action, if boonz-erp/.git/index.lock exists and its
mtime is more than 10 minutes old, move it to BOONZ BRAIN/_to_delete/index.lock.<YYYYMMDDHHMMSS>
(mv, not rm) and report "stale index.lock moved". If it is younger than 10 minutes leave it (a live git
process may own it) and report it. Change the last sentence of STEP 3 to "This environment must not
mutate the repo, with one exception (STEP 4)."
