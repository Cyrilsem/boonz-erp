# PRD-CLEAN-13 — Partner deliverables branch on the supply model

Status: DONE (2026-07-16) — both skills branch on get_venue_terms().source_of_supply
(originals kept as *.skill.bak-20260716). V1 formula-exact (276.65/69.16/207.49); V2 by
construction; V3 differential byte-identical (boonz path untouched); V4 differential exact
(registry delta +28.39 = post-issuance Eviron COGS backfill, pre-existing); tsc+build clean.
OPEN: v_slot_binding_drift=5 needs one attended rebind_slot_lifecycle_from_weimi run
(classifier-blocked; engines assert 0 at 16:00 UTC). Full log: DECISIONS.md.
Priority: P1
Approved by CS: yes (2026-07-15)

## Context

LevelUp (`venue_group='LVLUP'`) is a new partnership class: the venue sources 100% of
product, Boonz holds zero inventory and zero COGS, Boonz supplies the machine and takes
25% of net revenue, and Boonz does NOT refill. Boonz's contracted deliverable is
intelligence: sales, rev-share, and replenishment advice the partner executes themselves.

Three LVLUP machines were installed 2026-07-13 (LVLUP-1018-0000-G0, LVLUP-1048-0000-P0,
LVLUP-2015-0000-R0), relabelled `location_type='gym'`, `include_in_refill=false`.
10 partner products created (boonz `LevelUp - X` → pod `X`, `sourcing_channel='LevelUp
Kitchen'`, mapping `source_of_supply='venue_team'`, avg_cost NULL) + weimi aliases.
All 64 LVLUP Weimi slots resolve. Zero LVLUP rows in routes/plans/dispatch.

## Canonical source of truth

`public.commercial_agreements` — one row per venue_group (UNIQUE), 10 rows, no active
machine without one. Read it via `get_venue_terms(p_venue_group text)`.

Model columns (all NOT NULL as of 2026-07-15):

- `source_of_supply` — 'boonz' | 'venue_team'
- `boonz_bears_cogs`, `cogs_recovered_from_venue`, `boonz_refills`
- `boonz_share_pct` + `partner_share_pct` (CHECK: sum = 1)
- `adyen_pct` (0.026), `adyen_fixed_aed` (0.50)

CHECK constraints already prevent incoherent states: cannot recover COGS never borne;
a `venue_team` group cannot have `boonz_bears_cogs` or `boonz_refills` true.

| venue_group                                  | type            | boonz | supply     | cogs | recovered | refills |
| -------------------------------------------- | --------------- | ----- | ---------- | ---- | --------- | ------- |
| VOX                                          | VOX             | 20%   | boonz      | yes  | yes       | yes     |
| LVLUP                                        | PARTNER_SOURCED | 25%   | venue_team | no   | no        | no      |
| GRIT, OHMYDESK                               | REVENUE_SHARE   | 95%   | boonz      | yes  | no        | yes     |
| ADDMIND, AMAZON, INDEPENDENT, NOVO, VML, WPP | NONE            | 100%  | boonz      | yes  | no        | yes     |

NOTE: `venue_commercial_terms` was created earlier on 2026-07-15 and DROPPED the same day
as a duplicate of `commercial_agreements`. Do not recreate it.

## Scope

### 1. partner-performance-report skill

Branch on `get_venue_terms(<group>).source_of_supply`:

- `'boonz'` → current behaviour, unchanged.
- `'venue_team'` →
  - Waterfall has NO COGS leg. Settlement = net × `partner_share_pct`.
  - DELETE the replenishment/refill section (Boonz does not refill; `boonz_refills=false`).
  - REPLACE it with sell-through intelligence: velocity by product, empty and near-empty
    shelf incidence, and a suggested replenishment list the partner executes.

### 2. statement-of-account skill

Same branch. For `venue_team`: omit the "Boonz COGS" line;
Net Client Revenue = Net Sales × `partner_share_pct`.
Also honour `cogs_recovered_from_venue` — true ONLY for VOX (COGS deducted from venue
dues), false for GRIT/OhmyDesk (Boonz absorbs). This previously lived only in prose notes.
**VOX statement output must remain numerically identical to today.**

## Out of scope (separate PRD)

PRD-CLEAN-12: refactoring `get_vox_commercial_report` and siblings to read
`commercial_agreements` instead of hardcoded `v_boonz_pct := 0.20` / `v_adyen_pct := 0.026`.
The table is the declared truth; the functions still hold duplicates. Do not touch here.

## Verification

1. LVLUP report, period from 2026-07-13, reconciles to live data:
   35 txns / 302.00 AED gross / ~276.65 net → Boonz 69.16 / LevelUp dues 207.49.
2. LVLUP report contains no COGS line and no refill/replenishment-execution section.
3. Regenerate an existing OhmyDesk or GRIT report for a past period — output must be
   byte-identical to the pre-change version.
4. VOX statement for a fixed historical window — every monetary field identical to the fils.
5. `npx tsc --noEmit` clean.

## Gotchas

- LVLUP volume is tiny (35 txns since Monday). Two days is a data point, not a trend —
  the narrative must not over-read it.
- 6 of 10 LVLUP SKUs have never sold a unit (Yubi 29 units on shelf, Barakat 24).
  Surface this as merchandising intel, not as an error.
- `avg_cost` is NULL for all LevelUp products by design. Any COGS maths must be skipped,
  not defaulted to zero.
