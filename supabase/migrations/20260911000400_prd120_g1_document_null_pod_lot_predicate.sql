-- PRD-120 follow-up G1: reconcile the NULL-pod_lot_id Remove backlog count.
--
-- A hand query (action='Remove' AND pod_lot_id IS NULL AND NOT cancelled AND NOT skipped
-- AND NOT dispatched) returns 14. check_null_pod_lot_remove_legs() returns 11. The
-- difference is entirely the function's `quantity > 0` condition: it excludes 3 rows,
-- all dated 2026-04-13 on USH-1008-0000-W1, all "WIND DOWN" placeholder Remove legs with
-- quantity=0 (deliberately zero -- nothing physical to remove from the shelf). A
-- zero-quantity removal has no unit to bind to a lot, so pod_lot_id=NULL on those rows is
-- correct, not a defect. The function's `NOT returned` condition contributes zero
-- difference currently (0 of the 14 rows are returned=true) but is kept as a legitimate
-- defensive filter against a returned line being double-counted.
--
-- Conclusion: 11 is the right number. No functional change to the predicate -- it was
-- already correct. This migration only documents it via COMMENT ON FUNCTION so a future
-- hand query has the canonical predicate spelled out instead of re-deriving (and
-- disagreeing with) it from scratch.
--
-- Cody: fast-path approve, class (f) -- catalog comment only, no behavior change.

COMMENT ON FUNCTION public.check_null_pod_lot_remove_legs() IS
'Canonical NULL-pod_lot_id Remove-leg backlog assertion (PRD-120). Predicate: action=''Remove'' AND pod_lot_id IS NULL AND quantity > 0 AND NOT cancelled AND NOT skipped AND NOT returned AND NOT dispatched. The quantity > 0 condition is required, not optional: a zero-quantity Remove (e.g. a "WIND DOWN" placeholder line) has no physical unit to bind to a lot, so pod_lot_id=NULL on such a row is correct and must not be counted as a violation. A hand query reproducing this exact predicate will match this function''s count; a query omitting quantity > 0 will overcount by however many zero-quantity Remove legs currently exist and should not be treated as more authoritative than this function. See PRD-120-REPORT.md, item G1 (2026-09-11) for the reconciliation.';
