-- PRD-141c item 20 (Dispatch Detail: no qty tab on packed lines, per-line Saved confirmation) rollback.
-- FE only, no database change. git revert the commit "fix(prd-141): item 20 dispatch detail qty edits and save
-- confirmation" and push.
SELECT 1;
