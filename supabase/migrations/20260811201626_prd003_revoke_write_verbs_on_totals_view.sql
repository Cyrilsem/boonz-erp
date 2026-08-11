-- PRD-003 C-1 follow-through. The post-image read after part 1 showed
--   v_po_document_totals: {postgres=arwdDxtm/postgres, authenticated=arwdDxtm/postgres, ...}
-- S-308 applies to VIEWS as well as tables: the DEFAULT PRIVILEGE hands `authenticated` the full
-- verb set on every relation created in public, and `GRANT SELECT` does not take the others away.
-- The view is non-updatable (aggregates + CTEs), so a write would fail anyway — but "it would fail
-- anyway" is luck, not posture. Revoke by name.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.v_po_document_totals FROM authenticated;
GRANT SELECT ON public.v_po_document_totals TO authenticated;
