-- PRD-141c item 8 (pack outcome writes on tap) rollback. FE only, no database change.
-- Revert the commit "feat(prd-141): item 8 pack writes on tap" with git revert <sha> and push;
-- the packing screen then stages Packed taps until Save again, as before.
SELECT 1;
