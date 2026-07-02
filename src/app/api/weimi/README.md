# Weimi API routes - ARCHIVED (2026-07-03, PRD-072 WS-C)

These routes (`apply-capacity`, `apply-status`) and `src/lib/weimi.ts` are an
ARCHIVE of unshipped work from `feat/prd-033-operator-flexibility` (June 2026).

- NOT wired: nothing on main imports or calls them; they exist only on this
  archive branch (`archive/weimi-api-2026-06`), which is intentionally NOT
  merged to main.
- The LIVE capacity path is the n8n flow, not these routes.
- If Weimi direct-API integration is ever revived, start from these files but
  re-review auth + Article 3 (writes must go through canonical RPCs).
