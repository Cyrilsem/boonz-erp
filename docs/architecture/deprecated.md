# Deprecated registry

Article 13 requires that every deprecated RPC, table, or column is recorded here
with its deprecation date, expected removal date, and last-call timestamp, and
that a function is only dropped after 90 days of zero calls in
`pg_stat_user_functions`.

## ⚠️ Standing caveat — the Article 13 monitoring instrument is not running

`pg_stat_user_functions` returns NULL `calls` for **every** function in this
project, including `receive_purchase_order`, which is called daily. That means
`track_functions` is off at the server level, so the 90-day zero-call window
Article 13 prescribes cannot be measured on any object.

Until `track_functions` is enabled, every deprecation ruling has to fall back to
static evidence (repo grep, `pg_stat_statements`, `pg_proc.prosrc` cross-
references). Each entry below records which evidence was used.

**Open action:** enable `track_functions = 'pl'` so Article 13 becomes
enforceable. Raised by Cody during the PRD-022 review, 2026-08-15.

---

## Dropped

### `create_po_addition_v2(text, uuid, numeric, numeric, date, text, text)` — 7-arg signature

| Field         | Value                                                                                                                 |
| ------------- | --------------------------------------------------------------------------------------------------------------------- |
| Deprecated    | 2026-08-15                                                                                                            |
| Dropped       | 2026-08-15 (same migration)                                                                                           |
| Migration     | `po_pricing_status_v1_rpcs`                                                                                           |
| Replaced by   | `create_po_addition_v2(text, uuid, numeric, numeric, date, text, text, text)` — same function plus `p_pricing_status` |
| 90-day window | **Waived.** See rationale.                                                                                            |

**Rationale for waiving the window.** Article 13 exists to stop surprise
removals breaking n8n and integrations we did not know about. That risk is not
engaged here:

- The 7-arg function was created 2026-08-14 and dropped 2026-08-15 — a lifespan
  of one day.
- Zero callers in `src/` (grep for `create_po_addition`).
- Zero callers in `supabase/migrations/`.
- Zero references in `pg_stat_statements`.
- Zero references in any other function body (`pg_proc.prosrc`).

**Why it was dropped rather than left in place.** `CREATE OR REPLACE FUNCTION`
cannot add a parameter, so shipping the 8-arg version alongside would have left
two live signatures. PostgREST resolves by the keys the caller supplies, so the
7-arg form would have stayed reachable — and it accepts an addition with no
total and no free-goods assertion, which is the exact defect PRD-022 exists to
close. Keeping it would have been an Article 1 violation (two write paths, one
of them the broken one) to satisfy an Article 13 window whose own instrument is
not running.

Cody-reviewed and approved under Article 13's purpose clause, 2026-08-15.

---

## Deprecated, not yet dropped

### `rename_machine_in_place_legacy(...)`

| Field            | Value                                      |
| ---------------- | ------------------------------------------ |
| Deprecated       | pre-existing (see CLAUDE.md)               |
| Expected removal | not scheduled                              |
| Replaced by      | `repurpose_machine(p_old_machine_id, ...)` |

Older rename-in-place pattern still reached by legacy field PWA flows. Do not
call from new code. Removal blocked on the same `track_functions` gap above —
there is currently no way to prove the flows have stopped calling it.
