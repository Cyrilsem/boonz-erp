# PRD-003 - PO Document Totals: VAT, Discounts, Adjustments, Grand Total - BUILD REPORT

**Branch:** `prd-003-po-document-totals`
**Started:** 2026-08-11
**PRD:** `docs/prds/procurement/PRD-003-po-document-totals-vat-discount.md` (§12 CS rulings and §13 execution notes are binding)

---

## Leg 1 - 2026-08-11 - schema reconnaissance

Facts established against live production (`eizcexopcuoycuosittm`) before any design was written. Every one of these
changes something in the PRD as drafted, so they are recorded first.

**F-1. `purchase_orders` has no header row and no `cancelled` outcome.** The column `purchase_outcome` carries
exactly three values in production: `received` (828 rows), `not_purchased` (294), `NULL` (38). There is no
`cancelled`. The canonical cancel writer `cancel_po_line` sets `purchase_outcome = 'not_purchased'`, and `cancel_po`
delegates to it line by line. The PRD's view filter `purchase_outcome IS DISTINCT FROM 'cancelled'` is therefore a
**dead predicate** - it excludes nothing. It has to be `COALESCE(purchase_outcome,'') <> 'not_purchased'`, which is
also the exact predicate `add_purchase_order_lines` and `cancel_po_line` already use for the driver-task rebuild.

**F-2. `warehouse_inventory` has no cost column at all.** Columns are `wh_inventory_id, boonz_product_id,
snapshot_date, warehouse_stock, expiration_date, batch_id, wh_location, status, consumer_stock, created_at,
disposal_reason, reserved_for_machine_id, reservation_priority, reserved_at, warehouse_id, provenance_reason,
source_event_id, quarantined`. Cost is not stored on the batch; it is derived downstream through
`v_product_landed_cost`, which coalesces `boonz_products.avg_30days_cost` → `boonz_products.avg_cost` →
`product_mapping.avg_cost` → `pod_products.purchasing_cost`. None of those four is written by any Postgres function
in this database (a full `pg_get_functiondef ILIKE '%avg_30days_cost%'` sweep returns zero rows - the column is fed
from outside Postgres). This reshapes T11: the assertion cannot be "the cost column on the batch is unchanged",
because there is no such column. T11 becomes the two assertions that actually protect settlements, stated in the
test plan below.

**F-3. `receive_purchase_order` is the only writer that sets a received line's price**, and it sets
`price_per_unit_aed = COALESCE(v_new_price, price_per_unit_aed)` and `total_price_aed = received_qty × price`.
Nothing in this PRD may touch that function's price arithmetic.

**F-4. The additions leak is real and is worse than the PRD states.** Of 49 `po_additions` rows, **46 received
additions have no mirrored `purchase_orders` line**, one cancelled addition has none, and only 2 coincidentally
match a real line (PO-2026-9400 Vitamin Well Care and Antioxidant - those two were entered twice, once as an
addition and once as a line). So the leak is not "occasionally"; it is the default. Neither
`receive_purchase_order_addition` nor the `p_additions` branch of `receive_purchase_order` creates a
`purchase_orders` row - both credit `warehouse_inventory` and stamp `po_additions.status='received'`, full stop.

**F-5. `po_additions.price_per_unit_aed` is not reliably a unit price.** Live values include Twix Regular qty 50 @
"109.9", Nutella Biscuit T12 qty 24 @ "287.76", Vitamin Well Zero Lemon qty 12 @ "129.48", and the 2026-08-11
Union Coop incident row Perrier Grapefruit qty 10 @ "63". Those are pack/case totals typed into a unit-price field.
Naively valuing all unmirrored additions at `qty × price_per_unit_aed` gives **AED 23,664.20**, which is fiction.
This is the single most dangerous fact in the PRD: a backfill mirror would inject 46 rows of garbage unit prices
straight into `purchase_orders`, which is the ex-VAT cost spine. **No backfill.** The mirror is forward-only.

**F-6. The live-data VAT-regime warning in §12 is confirmed.** PO-2026-9400 Popcorn Butter is stored at 2.95/unit
(32.45/11) against a Union Coop bill ex-VAT unit of 2.81 - the stored line is VAT-inclusive. PO-2026-9260 stores
6.7094 / 6.7100 / 6.6700, which are ex-VAT back-computes. Both regimes coexist in the same table today with nothing
to tell them apart.

**F-7. Existing guardrails the design must not trip.** `trg_po_number_one_po_id` (BEFORE INSERT on
`purchase_orders`) refuses an insert whose `po_number` already belongs to a different `po_id`; a mirrored line
carrying the parent PO's own `po_number` passes it. `purchase_orders` RLS is `authenticated_read USING (true)` plus
`service_role_all`; there is no authenticated INSERT/UPDATE policy, so all writes are already SECURITY DEFINER-only.
`purchase_orders` is **not** in Constitution Appendix A (protected entities) - `warehouse_inventory` is.

---

## Leg 1 - Dara: schema design proposal

### Design problem

PRD-003 needs a document-level financial layer over a table that has no document. `purchase_orders` is line-grain
with `po_id` repeated and no unique key on it, so the totals row cannot be a column set and cannot carry a foreign
key. The layer must support four queries: (a) render one PO's totals block in a single call; (b) detect that lines
moved after totals were agreed; (c) report recoverable input VAT by month by supplier (CS ruling Q3 = YES); (d)
value a PO including the additions that currently leak out of it (CS §12 scope addition). It must protect one
invariant absolutely - recoverable input VAT is a receivable, never an inventory cost - which in this schema means
**no object created by this PRD may ever be read by a cost path, and no writer created by this PRD may ever write
`purchase_orders.price_per_unit_aed`**.

### Proposed schema

Two deviations from the PRD draft and one deviation from Dara's own D1 are flagged inline.

```sql
CREATE TABLE IF NOT EXISTS public.purchase_order_totals (
  -- D1 DEVIATION, deliberate: natural text PK, not a uuid surrogate. The table is
  -- strictly one row per po_id and every access is by po_id; a surrogate would add a
  -- second uniqueness rule to keep honest. No FK is possible (po_id is not unique on
  -- purchase_orders) - the RPC carries an EXISTS check instead.
  po_id                      text PRIMARY KEY,

  -- Snapshot at time of entry, split so a stale-detect can tell WHICH side moved.
  -- lines + additions = subtotal, enforced below.
  lines_subtotal_ex_vat_aed      numeric(12,2) NOT NULL DEFAULT 0,
  additions_subtotal_ex_vat_aed  numeric(12,2) NOT NULL DEFAULT 0,
  subtotal_ex_vat_aed            numeric(12,2) NOT NULL,

  discount_aed               numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_aed >= 0),
  discount_label             text,

  vat_rate                   numeric(6,4) NOT NULL DEFAULT 0.05
                               CHECK (vat_rate >= 0 AND vat_rate <= 1),
  vat_aed                    numeric(12,2) NOT NULL DEFAULT 0 CHECK (vat_aed >= 0),
  -- what the auto rule would have produced, kept so an override is provable later
  vat_auto_aed               numeric(12,2) NOT NULL DEFAULT 0,
  vat_is_override            boolean       NOT NULL DEFAULT false,

  other_adjustment_aed       numeric(12,2) NOT NULL DEFAULT 0,   -- signed
  other_adjustment_label     text,

  grand_total_aed            numeric(12,2) NOT NULL,             -- derived, never typed

  supplier_invoice_number    text,
  supplier_invoice_date      date,
  supplier_invoice_total_aed numeric(12,2),

  -- PRD §12 live-data warning F-6: which regime this PO's LINES are in.
  -- 'ex_vat' only when the new capture path produced them. Legacy stays 'unknown'.
  line_price_regime          text NOT NULL DEFAULT 'unknown'
                               CHECK (line_price_regime IN ('ex_vat','vat_inclusive','unknown')),

  source                     text NOT NULL DEFAULT 'receiving'
                               CHECK (source IN ('receiving','edit','backfill')),
  created_at                 timestamptz NOT NULL DEFAULT now(),
  created_by                 uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  last_edited_at             timestamptz,
  last_edited_by             uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,

  CONSTRAINT po_totals_subtotal_split_coherent CHECK (
    subtotal_ex_vat_aed = lines_subtotal_ex_vat_aed + additions_subtotal_ex_vat_aed
  ),
  CONSTRAINT po_totals_grand_total_coherent CHECK (
    grand_total_aed = subtotal_ex_vat_aed - discount_aed + vat_aed + other_adjustment_aed
  ),
  -- PRD §4 note: "an unexplained adjustment is how reconciliation rots." The PRD put
  -- these in the RPC only. Dara puts them in the table too - a label rule that lives
  -- only in a function is a label rule that a second writer will forget.
  CONSTRAINT po_totals_discount_labelled CHECK (
    discount_aed = 0 OR (discount_label IS NOT NULL AND length(btrim(discount_label)) > 0)
  ),
  CONSTRAINT po_totals_adjustment_labelled CHECK (
    other_adjustment_aed = 0 OR (other_adjustment_label IS NOT NULL AND length(btrim(other_adjustment_label)) > 0)
  )
);
```

Second object - the additions mirror needs an exact line↔addition link, otherwise the mirror is not idempotent and
the view cannot avoid double-counting the 2 coincidental duplicates in F-4:

```sql
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS source_addition_id uuid;   -- nullable: legacy lines have none

CREATE UNIQUE INDEX IF NOT EXISTS uq_purchase_orders_source_addition
  ON public.purchase_orders (source_addition_id) WHERE source_addition_id IS NOT NULL;
```

Additive, nullable, zero rewrite of existing rows. The partial UNIQUE index is what makes
`mirror_po_addition_line` safe to call twice: the second call is a no-op, not a duplicate line. `purchase_orders`
is not a protected entity (F-7), so this is an ordinary additive column.

### Indexes

```sql
-- serves: get_po_document_totals / the FE card, one PO at a time
--   (the PK on po_id already covers this - no extra index)

-- serves: get_input_vat_report - SUM(vat_aed) sliced by month over invoice date
CREATE INDEX IF NOT EXISTS idx_po_totals_invoice_date
  ON public.purchase_order_totals (supplier_invoice_date) WHERE supplier_invoice_date IS NOT NULL;

-- serves: the same report when the supplier issued no dated invoice, and the audit sweep
CREATE INDEX IF NOT EXISTS idx_po_totals_created_at
  ON public.purchase_order_totals (created_at DESC);

-- serves: the additions fold-in in v_po_document_totals and the mirror's dedup lookup
CREATE INDEX IF NOT EXISTS idx_po_additions_po_status
  ON public.po_additions (po_id, status);
```

D5: each index names its query. No index on `po_id` in `purchase_order_totals` - the PK is that index.

### RLS policies

Read-open to `authenticated`, matching `purchase_orders.authenticated_read`. Writes denied at table level so the
only path in is the SECURITY DEFINER RPC (Article 3). No policy on this table queries another table, so it cannot
recreate the `user_profiles` recursion class of bug.

```sql
ALTER TABLE public.purchase_order_totals ENABLE ROW LEVEL SECURITY;

CREATE POLICY po_totals_select    ON public.purchase_order_totals FOR SELECT TO authenticated USING (true);
CREATE POLICY po_totals_no_insert ON public.purchase_order_totals FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY po_totals_no_update ON public.purchase_order_totals FOR UPDATE TO authenticated USING (false);
CREATE POLICY po_totals_no_delete ON public.purchase_order_totals FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.purchase_order_totals TO authenticated;
REVOKE ALL   ON public.purchase_order_totals FROM anon;
```

The RPCs are `EXECUTE TO authenticated` only, never `anon` - PRD-113 leg 4 established that a freshly created
function is `anon`-executable by default in this project, so the REVOKE is explicit, not assumed.

### The view, corrected

The PRD's `v_po_document_totals` has three defects that would ship wrong numbers. Restated:

1. **Dead filter (F-1).** `purchase_outcome IS DISTINCT FROM 'cancelled'` matches every row in the table. Replaced
   with `COALESCE(purchase_outcome,'') <> 'not_purchased'`.
2. **Additions invisible (F-4).** Aggregating `FROM purchase_orders` alone can never see an addition, because the
   addition has no line. The fold-in is a separate scalar aggregate over `po_additions`, restricted to
   `status='received'` and `source_addition_id IS NULL` on the line side so a mirrored addition is counted once, as
   a line, not twice.
3. **Honesty about F-5.** The addition value is exposed as its own column, and carries a
   `additions_price_suspect` flag rather than being silently blended into one number. CS ruled "the view must count
   additions until backfilled" - it counts them, and it says out loud when the price it counted them at is a pack
   total.

`totals_stale` compares the stored snapshot against the same live definition the RPC snapshots, on both the lines
side and the additions side, so a late addition trips the chip exactly as a late line edit does.

### Tradeoffs and alternatives

**Rejected: make `grand_total_aed` a GENERATED ALWAYS column.** It reads cleaner than a CHECK. Rejected because
PRD-098 already banked the lesson that a generated column is a trapdoor - `quarantined` on `warehouse_inventory` is
GENERATED, and every writer that tried to set it raised. A CHECK gives the identical guarantee (the row cannot be
internally inconsistent) while leaving the value writable by the one RPC that computes it, and leaves room for the
`source='backfill'` path in PRD §7 to insert a historical figure.

**Rejected: mirror the 46 historical additions in a backfill migration.** This is what "the totals view must count
additions until backfilled" invites, and it is the wrong move. F-5 shows the historical prices are pack totals;
mirroring them writes AED 23.6k of fiction into the ex-VAT cost spine that feeds `product_mapping.avg_cost` and
`v_product_landed_cost` and therefore every partner settlement. Forward-only mirror, view-level fold-in for
history, and the numbers stay traceable to what was actually typed. This also honours PRD §7 "No backfill" and I-2.

**Rejected: put the mirror in a trigger on `po_additions`.** Tempting - it would catch every writer including any
future one. Rejected because a trigger firing an INSERT into `purchase_orders` inside the `receive_purchase_order`
transaction makes the failure mode invisible (the receive succeeds, the mirror silently rolls back or silently
succeeds, and no one can tell which), and because D6's "audit by trigger" applies to audit rows, not to business
rows. An explicit helper called from the two known receive paths keeps the mirror in one place and keeps its errors
attributable.

**Rejected: extend `edit_purchase_order_line` to carry VAT.** It is the established pattern this PRD copies, but
extending it would put a VAT parameter on the one writer that sets `price_per_unit_aed`. That is precisely the
adjacency I-1 exists to prevent. Separate writer, separate table, no shared parameter surface.

**Accepted with a cost: the `line_price_regime` column is advisory, not derived.** It records what the capture path
believed, and legacy rows stay `'unknown'` forever. A derived flag (by capture date) was considered and rejected -
F-6 shows both regimes inside the same week, so a date cutoff would mislabel real rows.

### Cody handoff checklist

This design must be ruled on against:

- **Article 2** (RLS shape) - deny-write policies, `(SELECT auth.uid())` form wherever uid appears, no cross-table
  policy predicate.
- **Article 3** (no direct table writes from FE) - writes SECURITY DEFINER only, `anon` revoked explicitly.
- **Article 4** (audit) - `procurement_events` + `write_audit_log` on every write, including the mirror.
- **Article 6** (`warehouse_inventory.status` manager-only) - assert nothing here writes it. The mirror writes
  `purchase_orders` only, never `warehouse_inventory`; the WH credit stays where it is today.
- **Article 7** (state transitions validated by RPC) - `source` and `po_additions.status` transitions.
- **Article 12 / 14** (naming, no duplicate function identities) - `pg_proc` checked before creating each function.
- **Article 16** (metrics registry) - `v_po_document_totals` is a new canonical read object and needs registering.
- **Appendix A** - proposal adds nothing to the protected list; `purchase_order_totals` is a financial-reconciliation
  table with no path into refill, packing, dispatch or stitch (PRD I-3), and Dara does not propose protecting it.

---

## Leg 1 - Cody: constitutional review

Knowledge base loaded and readable: `01_constitution.html`, `02_phase_a_plan.html`, `03_a1_before_after.html`,
`CHANGELOG.md` (460 KB), `MIGRATIONS_REGISTRY.md` (660 KB), `RPC_REGISTRY.md` (509 KB), `METRICS_REGISTRY.md`
(244 KB). No document missing, so a verdict is admissible.

**Verdict:** ⚠️ Approve with revisions - **9 conditions, none waivable.** One of them (C-3) is a live conservation
break that the proposal as written would have shipped.

**Change classification:** (a) DDL - new table `purchase_order_totals`, additive column on `purchase_orders`;
(b) writer DEFINER - `set_po_document_totals`, the additions mirror; (c) read-only DEFINER -
`get_po_document_totals`, `get_input_vat_report`, view `v_po_document_totals`. All three classes reviewed.

**Articles checked:** 1, 2, 3, 4, 6, 7, 8, 12, 14, 16, plus Appendix A and the S-308 default-privilege rule.

### Findings

**Article 14 ✅.** `purchase_order_totals` is not a snapshot table. It holds captured document facts - what the
supplier's paper said, what a human entered, when, and why - which no view can derive from `purchase_orders`,
because the source is a piece of paper. The `subtotal_ex_vat_aed` column is the one that looks like a cache; it is
not, it is a **point-in-time snapshot whose divergence from live is the product** (`totals_stale`). Article 14's
test is silent staleness. This design makes staleness loud. No ADR required.

**Article 2 ✅ / Article 3 ⚠️ → C-1.** The policy shape is right and no policy predicate touches a second table, so
the `user_profiles` recursion class is avoided. But **S-308 applies and the proposal misses it.** A Supabase
DEFAULT PRIVILEGE grants `authenticated` INSERT/UPDATE/DELETE/TRUNCATE on every table created in `public`. Dara's
migration grants SELECT and revokes `anon` - the SELECT grant is a **no-op** (already held), and the `anon` revoke
does not touch what `authenticated` holds. The deny-write RLS policies would be the only thing standing between the
FE and a direct write, and RLS covering it is luck, not posture.

**Article 1 ⚠️ → C-2. This is the finding that nearly broke the design.** PRD-022 D3b established, on my own
review, that `purchase_orders` has exactly two INSERT writers - `create_purchase_order` and
`add_purchase_order_lines` - and that **"two INSERT writers is the ceiling."** `mirror_po_addition_line` as
proposed would be a third. The ceiling is not negotiable, but it is a ceiling on _caller-reachable_ write paths,
and there is a live precedent for exactly this shape: `_resolve_open_walkin_po_v3` (PRD-110 P4.4b) is a DEFINER
that participates in writes to `purchase_orders` while holding ACL `{postgres=X,service_role=X}` - **no `anon`, no
`authenticated`** - because it is reached only as definer, from a canonical writer. The mirror takes that form. The
INSERT then remains attributable to `receive_purchase_order` and `receive_purchase_order_addition`, both of which
are already canonical writers on this table, and the count of caller-reachable INSERT paths stays at two.

**⛔ Conservation ❌ → C-3. BLOCKING. The mirror as specified double-counts every addition in a live reconciliation
view.** `v_daily_flow_reconciliation` builds `po_in` as `SUM(purchase_orders.received_qty) WHERE received_date IS
NOT NULL` and, separately, `addn_in` as `SUM(po_additions.qty) WHERE status='received'`, then computes:

```
net_wh_flow = procurement_in_po + procurement_in_additions + wh_in_from_returns - wh_out_to_packs
```

Both terms are added. The moment a mirrored `purchase_orders` line carries `received_qty = addition.qty` and a
`received_date`, that addition's units land in **both** `po_in` and `addn_in`, and `net_wh_flow` overstates
warehouse intake by exactly the addition quantity, per product, per day, forever. This is a conservation law, it is
the one the health playbook reconciles against, and PRD-003 would have quietly broken it on the first receive after
merge. The fix is not optional and is not a follow-up: `addn_in` (and the `date_product` UNION arm that feeds it)
must exclude additions that have been mirrored, in the **same migration** that introduces the mirror. The mirrored
line then carries the qty honestly and the addition stops being counted a second time. `CREATE OR REPLACE VIEW`
preserves the column list, so no consumer breaks.

**Article 6 ✅, and state it in the migration.** Nothing in this PRD writes `warehouse_inventory`, let alone
`warehouse_inventory.status`. The mirror creates a `purchase_orders` row and **no warehouse batch** - the WH credit
stays exactly where it is today, in the receive path. This is the same D-E discipline `receive_spot_fill_po_v3`
carries, and for the same reason: adding the "missing" batch would resurrect a netting design that drives
`tg_propose_inactivate_on_zero_stock` into an Article 6 manager-only `status` UPDATE. Do not repair the absent
batch. → C-8.

**Article 8 ⚠️ → C-4.** `purchase_orders` has **no `audit_log_write` trigger** (verified - the table carries only
`trg_po_number_one_po_id`). The universal audit does not cover it and has not covered any of its 8 existing DEFINER
writers. Every writer this PRD adds must therefore dual-write `procurement_events` **and** `write_audit_log`
explicitly, the way `edit_purchase_order_line` and `cancel_po_line` do. New event types must be distinct from
`goods_received` so the mirror is legible in the domain audit.

**Article 4 ⚠️ → C-5.** Standard: `set_config('app.via_rpc','true',true)` + `app.rpc_name` in every new writer,
role gate read from `user_profiles.role` (never `auth.jwt()`), `(SELECT auth.uid())` form, NULL and existence
validation on every input. The proposal assumes these; I want them enumerated in the body, not assumed.

**Article 12 ✅ conditional → C-9.** Forward-only, `CREATE ... IF NOT EXISTS`, no edit of a past migration.
Filename must be `YYYYMMDDHHMMSS_*.sql` with a **real** time component - the Round 2.5 incident (minute `75`) had
migrations silently skipped by the runner while sitting committed in the repo.

**Article 16 ⚠️ → C-6.** `v_po_document_totals` becomes the canonical object for "PO document grand total" and
"recoverable input VAT". It must be registered in `METRICS_REGISTRY.md`, and the FE must read it rather than
re-deriving the arithmetic client-side - which is, per PRD §2, precisely how this problem was created.

**Grant layer ⚠️ → C-7.** D-41/D-42 found 5 plan-committing DEFINERs reachable by `anon`, and four of the five
carried an explicit **PUBLIC** grant, so revoking `anon` alone would have left
`has_function_privilege('anon', …)` TRUE. `anon` holds `USAGE` on schema `public`, so this is a live path, not a
dormant grant. Every function created here revokes from **`anon` and `PUBLIC`**, and the ACL is read back and
asserted whole.

**Invariant I-2, elevated to a constitutional condition → C-0.** The PRD's own I-2 (VAT never reaches
`warehouse_inventory`, COGS, or any Statement of Account) is enforceable as a schema property, so enforce it as
one: **no object created by this PRD may be referenced by any cost path.** The cost path is
`v_product_landed_cost` → `boonz_products.avg_30days_cost` / `avg_cost` → `product_mapping.avg_cost` →
`pod_products.purchasing_cost`. That is the T11 assertion, and it must be a standing check, not a one-time test.

### Binding conditions (not waivable)

| #   | Condition                                                                                                                                                                     | Article      |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| C-0 | No PRD-003 object appears in any cost path. Asserted by a standing check over `pg_depend`/view bodies, not only by T11.                                                       | I-2, 16      |
| C-1 | Explicit `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON purchase_order_totals FROM authenticated`, with the post-image ACL read back and pasted into the report.                 | 3, S-308     |
| C-2 | The mirror is an internal definer-only helper (`_` prefix), ACL exactly `{postgres=X,service_role=X}`. No `authenticated`, no `anon`. Two caller-reachable INSERT paths, max. | 1            |
| C-3 | **BLOCKING.** `v_daily_flow_reconciliation` patched in the same migration so a mirrored addition is counted once, not twice. Proven with a before/after `net_wh_flow` read.   | conservation |
| C-4 | Every new writer dual-writes `procurement_events` + `write_audit_log`. `purchase_orders` has no audit trigger.                                                                | 8            |
| C-5 | `app.via_rpc` / `app.rpc_name` set; role gate via `user_profiles`; `(SELECT auth.uid())`; inputs validated.                                                                   | 4            |
| C-6 | `v_po_document_totals` registered in `METRICS_REGISTRY.md`; FE reads it instead of re-deriving.                                                                               | 16           |
| C-7 | `REVOKE EXECUTE ... FROM anon, PUBLIC` on every new function; ACL read back and asserted whole.                                                                               | 3, D-41/D-42 |
| C-8 | No `warehouse_inventory` write anywhere in this PRD. The mirror creates no batch, and the absent batch is not "repaired".                                                     | 6            |
| C-9 | Forward-only migration, `YYYYMMDDHHMMSS_` prefix with a valid time component, own files only.                                                                                 | 12           |

### Next action

Apply as `prd003_po_document_totals_vat` once C-0 through C-9 are in the migration body. Update `CHANGELOG.md`,
`MIGRATIONS_REGISTRY.md`, `RPC_REGISTRY.md` and `METRICS_REGISTRY.md` citing Articles 1, 3, 4, 8, 12, 16.

---

## Leg 1 - T11, restated against the real schema

The PRD writes T11 as "`warehouse_inventory` cost after receipt - unchanged by VAT, assert equal to ex-VAT unit
price". Finding F-2 shows `warehouse_inventory` has no cost column, so that assertion cannot be executed as
written. T11 becomes three assertions that carry the same protection:

- **T11a.** After `set_po_document_totals` runs on a received PO, every `purchase_orders` row for that `po_id` has
  `price_per_unit_aed` and `total_price_aed` byte-identical to their pre-call values. The totals writer never
  touches the ex-VAT spine.
- **T11b.** `v_product_landed_cost.landed_cost` for every product on that PO is unchanged across the same call.
  This is the actual input to COGS and the Statement of Account.
- **T11c.** No object created by PRD-003 is reachable from `v_product_landed_cost`, `boonz_products.avg_cost`,
  `boonz_products.avg_30days_cost`, `product_mapping.avg_cost` or `pod_products.purchasing_cost`. Structural, so
  it stays true for code not yet written. This is C-0.

---

## Leg 1 - build applied

Five migrations, all additive, all forward-only, repo filenames matching the applied
`supabase_migrations.schema_migrations.version` byte for byte:

| version          | name                                                | contents                                                                                                                |
| ---------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `20260811201329` | `prd003_po_document_totals_vat`                     | table + RLS + S-308 revoke, `source_addition_id` + partial UNIQUE, `v_po_document_totals`, **C-3 reconciliation patch** |
| `20260811201443` | `prd003_po_totals_rpcs_and_addition_mirror`         | the three RPCs + the internal mirror, anon/PUBLIC revokes                                                               |
| `20260811201550` | `prd003_wire_addition_mirror_into_receive_paths`    | both receive paths rebuilt from live bodies, one added statement each                                                   |
| `20260811201626` | `prd003_revoke_write_verbs_on_totals_view`          | S-308 follow-through on the view                                                                                        |
| `20260811202358` | `prd003_procurement_events_admit_totals_and_mirror` | widens the `event_type` CHECK                                                                                           |

Two things were found only by applying and rehearsing, and both would have been production failures:

**The `event_type` CHECK.** `procurement_events.event_type` is a closed CHECK enum. The very first
`set_po_document_totals` call in the dry run raised `23514`. Nothing in the PRD, the schema
reconnaissance or either review predicted it - the constraint is invisible unless you read
`pg_constraint` or you try. Migration `20260811202600` widens it by the three new values. Without the
rehearsal this lands on the first real receive after deploy.

**S-308 applies to views.** After migration 1 the post-image read
`v_po_document_totals: {postgres=arwdDxtm, authenticated=arwdDxtm, service_role=arwdDxtm}`. The
default privilege hands `authenticated` the full verb set on every _relation_ in `public`, not just
every table, and `GRANT SELECT` does not take the rest away. Closed by migration 4.

### Condition post-images

| #   | Condition                                   | Evidence                                                                                                                                                     | State |
| --- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| C-0 | no PRD-003 object in any cost path          | `view_refs_prd003 = (none)`, `any_cost_named_fn_refs_prd003 = (none)`, `engine_objects_ref_prd003 = (none)`; the only dependent of the table is its own view | ✅    |
| C-1 | write verbs revoked from `authenticated`    | table ACL `authenticated=rm/postgres`; `has_table_privilege` INSERT/UPDATE/DELETE all **false**, SELECT true                                                 | ✅    |
| C-2 | mirror is definer-only                      | `_mirror_po_addition_line_v1` ACL is exactly `{postgres=X/postgres,service_role=X/postgres}`; `has_function_privilege('authenticated', …) = false`           | ✅    |
| C-3 | reconciliation does not double-count        | live delta test below: +10 units → `net_wh_flow` +10 patched, counterfactual unpatched +20                                                                   | ✅    |
| C-4 | dual audit on every writer                  | `procurement_events` + `write_audit_log` inserts in both `set_po_document_totals` and `_mirror_po_addition_line_v1`                                          | ✅    |
| C-5 | GUC + role gate + validation                | `app.via_rpc` / `app.rpc_name` set before the write; role read from `user_profiles`; `(SELECT auth.uid())`; T3/T6/T9 prove the guards fire                   | ✅    |
| C-6 | metrics registry                            | `METRICS_REGISTRY.md` PRD-003 section added; both FE surfaces read `get_po_document_totals` instead of re-deriving                                           | ✅    |
| C-7 | anon + PUBLIC revoked on every new function | `has_function_privilege('anon', …) = false` on all four                                                                                                      | ✅    |
| C-8 | no `warehouse_inventory` write              | M2 below: exactly one batch created per addition receive, by the pre-existing receive path                                                                   | ✅    |
| C-9 | forward-only, valid timestamps, own files   | five `YYYYMMDDHHMMSS_` filenames with real time components; no past migration edited                                                                         | ✅    |

---

## Leg 1 - test results

Every test ran as a DO block that performs the writes, measures the assertions, then `RAISE`s so the
transaction unwinds (the PRD-016B dry-test pattern). Verified afterwards:
`SELECT count(*) FROM purchase_order_totals` → **0**. Production carries none of this.

| #    | Case                                             | Measured                                                                       | Verdict |
| ---- | ------------------------------------------------ | ------------------------------------------------------------------------------ | ------- |
| T1   | PO-2026-9260, VAT auto                           | subtotal 254.77, VAT 12.74, grand 267.51, variance **−0.01** vs invoice 267.52 | ✅      |
| T2   | after correcting Activia Honey to 107.36         | subtotal 254.78, VAT 12.74, grand **267.52**, variance **0.00**                | ✅      |
| T3   | discount 20.00, no label                         | raised `discount_label is required when discount > 0`                          | ✅      |
| T4   | discount 20.00 labelled "Promo"                  | VAT 11.74 on 234.77, grand 246.51                                              | ✅      |
| T5   | VAT typed as 0 (exempt supplier)                 | accepted, grand = subtotal 254.77, `vat_override_warning` returned             | ✅      |
| T6   | edit with a 5-char reason                        | raised `reason is required on edit (>= 10 chars)`                              | ✅      |
| T7   | line price edited after totals captured          | `totals_stale = true`, stored 254.77 vs live 254.78                            | ✅      |
| T8   | PO-2026-9221, no totals row                      | `has_totals=false`, grand NULL, variance NULL, `totals_stale=false`            | ✅      |
| T9   | field_staff calls the RPC                        | raised `forbidden for role field_staff`                                        | ✅      |
| T10  | confirm with a red variance                      | succeeded, variance +895.58 recorded, nothing blocked                          | ✅      |
| T11a | ex-VAT spine after every totals write            | `price_per_unit_aed` / `total_price_aed` byte-identical on all untouched lines | ✅      |
| T11b | `v_product_landed_cost` after every totals write | `landed_cost` identical for every product on the PO                            | ✅      |
| T11c | structural: no PRD-003 object in a cost path     | see C-0                                                                        | ✅      |

**T11 is the one that matters, and it is now three assertions instead of one** - see F-2. The PRD
asked for "`warehouse_inventory` cost unchanged", but that column does not exist; cost is derived
downstream. T11a pins the ex-VAT spine, T11b pins the number that actually reaches COGS and the
Statement of Account, and T11c makes it structural so it stays true for code not yet written.

### The additions mirror

| #   | Case                                         | Measured                                                                             | Verdict |
| --- | -------------------------------------------- | ------------------------------------------------------------------------------------ | ------- |
| M1  | receive an addition via the addition path    | a `purchase_orders` line appears, returned as `mirrored_po_line_id`                  | ✅      |
| M2  | Article 6 / C-8: warehouse batches created   | `wh_before 6 → wh_after 7` - exactly **one**, by the pre-existing receive path       | ✅      |
| M3  | the mirrored line carries the money          | qty 10, unit 6.30, total **63.00**, outcome `received`, po_number 9400, supplier set | ✅      |
| M4  | idempotency                                  | second `_mirror_po_addition_line_v1` call returns the same id, still exactly 1 row   | ✅      |
| M5  | the PO subtotal counts the addition **once** | live subtotal 1075.65 → 1138.65, delta exactly **63.00**                             | ✅      |

### C-3, the conservation proof

The first run of this test **failed**, and the failure was in the test, not the code: it asserted
`procurement_in_additions = 0` for Perrier Grapefruit on 2026-08-11 while a _pre-existing, unmirrored_
addition of the same product on the same date was legitimately contributing 10 units there. Restated
as a delta against a clean product, with the unpatched behaviour computed explicitly alongside:

| measure                                          | value   |
| ------------------------------------------------ | ------- |
| units actually received                          | 10      |
| `procurement_in_po` delta                        | **+10** |
| `procurement_in_additions` delta                 | **0**   |
| `net_wh_flow` delta (patched)                    | **+10** |
| `net_wh_flow` the unpatched view would have read | **+20** |

Conservation holds: ten units in, ten units counted. The counterfactual column is the point - without
the patch this PRD ships a permanent, silent, per-product, per-day overstatement of warehouse intake.

---

## Leg 2 - 2026-08-12 - the merge gate

Three defects were found at the gate, none of them in the PRD-003 SQL. Two were in the record, one
was in the harness that was supposed to be judging the record. All three are the kind that ship a
false green, so each is written down with the evidence that settled it.

### G-1. The migration ledger disagreed with production

Leg 1 recorded the fifth migration as `20260811202600` and asserted the repo filenames matched the
applied `supabase_migrations.schema_migrations.version` "byte for byte". They did not. Production
recorded **`20260811202358`**; the repo file was named `20260811202600`. Same name, different
version - so the repo carried a migration the runner would consider unapplied, and `db push` would
have re-run it. The DDL is a `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`, so re-running is
harmless in effect, which is exactly what makes this class of drift survive unnoticed.

Repo file renamed to `20260811202358_prd003_procurement_events_admit_totals_and_mirror.sql`; the
table above corrected. The applied ledger is the source of truth and the repo now mirrors it. This
is the Round 2.5 lesson from `CLAUDE.md` arriving from the other direction: there, valid-looking
filenames were never applied; here, an applied migration carried a filename nothing would match.

Live constraint verified to carry all three new event types (`po_totals_set`, `po_totals_edited`,
`po_addition_line_mirrored`), so the DDL itself is correct and applied.

### G-2. Prettier churn had spilled into three other PRDs' files

The working tree carried uncommitted reformatting of `PRD-112-REPORT.md`, `PRD-113-REPORT.md` and
`field/dispatching/[machineId]/page.tsx` - markdown table padding, `*x*` → `_x_`, one line-wrap.
Content-free, but out of scope per §13 ("own files only"). All three reverted. The dispatching page
is PRD-113's `internal_move_return_blocked` branch and this PRD has no business touching it.

### G-3. ⛔ The golden harness was manufacturing a false red - and could have manufactured a false green

The first gate run reported **fixture 18 red**, 79/80, on seq 70:

> ⛔ `app.via_rpc` is RESTORED after the RPC returns. These GUCs leak across statements in this
> codebase (PRD-016B); a spot buy that left via_rpc set would make the next unrelated write look
> like an RPC.

Expected `''`, actual `'true'`. Fixture 18 had been green 80/80 in **every** run through 2026-08-09,
and the only migrations between that run and this one were PRD-113's `a1`–`a10` and PRD-003's five.
It read exactly like a regression this PRD had introduced, and it is a conservation-adjacent
provenance assertion, so it was treated as blocking.

It is not a regression. **It is an artifact of the harness a previous leg of this relay built.**

Job 51 `prd003_golden_gate` ran **six fixtures per tick inside one DO block**, therefore inside **one
transaction**. `set_config(..., is_local => true)` is transaction-scoped, not statement-scoped, so a
GUC set by any fixture persists to COMMIT - across the fixture boundary and into every fixture that
follows it in the same tick. The historical green runs came from the PRD-110 sweep, which fires one
fixture per HTTP call and therefore one fixture per transaction. The suite was never designed to be
batched.

Proof, run alone in its own transaction:

| run                         | isolation          | result          | seq 70 actual |
| --------------------------- | ------------------ | --------------- | ------------- |
| `PRD-003 gate` (6-per-tick) | shared transaction | **79/80 RED**   | `true`        |
| `prd003-isolation-probe`    | own transaction    | **80/80 GREEN** | `''` (empty)  |

No code change between the two. The fixture is green; the harness was wrong.

The dangerous half is the converse, and it is why this was not simply worked around: a batched
harness leaks GUCs _forward_, so a fixture asserting that a GUC **is** set can pass on a value some
earlier fixture left behind. That is a **false green**, and a false green in the suite that gates
every merge is worth more than any one fixture's red. Job 51 was rebuilt to **one fixture per tick**:
pg_cron gives each invocation its own transaction, restoring the exact isolation the historical
baseline had, keeping the advisory-lock overlap guard and the cron-44 straddle guard (fixtures 2,
19, 20, 21, 22, 27 assert `shelf_composition` snapshot-at-start vs live-at-end; cron 44 rewrites
that table at `:40` every hour).

An earlier attempt to drive the suite from the shell was abandoned and is recorded so it is not
retried: the Supabase Management API sits behind a ~100 s Cloudflare ceiling (524), and the
statement is **cancelled** on gateway disconnect rather than continuing server-side - verified
against `pg_stat_activity`, and by fixture 2 committing nothing. Six fixtures exceed 90 s (37, 36,
42, 43, 7, 16; max 115 s), so no shell-driven runner can carry this suite. The work has to run
inside the database.

The contaminated `PRD-003 gate` rows are superseded by `PRD-003 gate v2`, adjudicated below.

---

## Leg 3 - 2026-08-11/12 - the Q3 deliverable that was built but never surfaced

### G-4. `get_input_vat_report` existed, was registered, and no screen read it

CS ruled **Q3 = YES** in §12: the recoverable input-VAT report ships in v1. Leg 1 built the RPC,
gave it the right ACL, indexed `purchase_order_totals.supplier_invoice_date` specifically to serve
it, and registered it in `METRICS_REGISTRY.md` as a canonical object. A grep of `src/` for
`get_input_vat_report` returned **zero call sites**.

A function nobody can call is not a report. Finance reads screens, not `pg_proc`. Q3 was therefore
open, not closed, and the gate would have merged a PRD with a binding CS ruling unfulfilled - with
every artifact around the hole present and correct, which is exactly what makes this class of gap
survive a review.

Closed on the procurement page: a fourth tab, **Input VAT**, with a From/To period filter, one row
per month per supplier (POs, subtotal ex-VAT, discount, recoverable VAT, grand total, and a count of
manual VAT overrides), and a footer total. It reads `get_input_vat_report` and does no VAT
arithmetic of its own - C-6, and the §2 lesson that client-side arithmetic is how this problem was
created in the first place.

The tab-visibility guard had to change with it. The PO table was gated on `tab !== "demand"`, which
would have rendered the order list underneath the new report. Replaced with an explicit
`isPOListTab = tab === "pending" || tab === "all"`, so a fifth tab later cannot reintroduce the same
bug by omission.

### T12 - the report against real POs

Run as a `DO` block that writes, measures, then `RAISE`s so the transaction unwinds. Verified after:
`SELECT count(*) FROM purchase_order_totals` → **0**. Production still carries no totals rows.

| measure                                    | value                                                            |
| ------------------------------------------ | ---------------------------------------------------------------- |
| rows returned                              | 2 - one per supplier, both in `2026-08`                          |
| Merich Global Wholesalers (PO-2026-9260)   | 1 PO, subtotal 254.77, VAT **12.74**, grand 267.51, overrides 0  |
| Union Coop (PO-2026-9400), VAT forced to 0 | 1 PO, subtotal 1075.65, VAT **0.00**, grand 1075.65, overrides 1 |
| footer total recoverable input VAT         | **12.74 AED**                                                    |
| override warning on the zero-VAT PO        | `vat_override_warning`, auto would have been 53.78 (dev 53.78)   |

The override count is the column that earns its place: a period whose VAT was hand-typed is a period
finance should look at before filing, and the report says so without anyone having to ask.

### Verify gates re-run after the change

| gate               | result                                                                            |
| ------------------ | --------------------------------------------------------------------------------- |
| `npx tsc --noEmit` | clean, exit 0                                                                     |
| `npm run build`    | exit 0                                                                            |
| `npm run lint`     | 148 problems (98 errors, 50 warnings) - **byte-identical to the `main` baseline** |

The lint number was measured, not assumed: `main` was checked out into a throwaway worktree with
`node_modules` symlinked and linted independently. It reports the same 148/98/50. Every finding in a
PRD-003 file (`set-state-in-effect` on the page components, one unused `today`) is present on `main`
at the same site. PRD-003 adds no lint debt.

### C-3 coverage sweep - is `v_daily_flow_reconciliation` the only double-count surface?

Cody found one aggregator that adds `purchase_orders` and `po_additions` together and patched it.
One is a finding; the question is whether it is the _only_ one. Swept every relation and every
function body in `public`:

| object                            | kind     | mirror guard (`source_addition_id`)   |
| --------------------------------- | -------- | ------------------------------------- |
| `v_daily_flow_reconciliation`     | view     | ✅ present (C-3 patch)                |
| `v_po_document_totals`            | view     | ✅ present                            |
| `set_po_document_totals`          | function | ✅ present                            |
| `_mirror_po_addition_line_v1`     | function | ✅ present (its own idempotency)      |
| `receive_purchase_order`          | function | n/a - a writer; it _calls_ the mirror |
| `receive_purchase_order_addition` | function | n/a - same                            |

Those six are the complete set of objects in `public` that name `po_additions`. Every one that
**aggregates** carries the guard; the two that do not are the writers that create the mirrored line
in the first place. There is no third surface where an addition can be counted twice.

Also confirmed at the same time: no golden fixture md5-pins `receive_purchase_order` or
`receive_purchase_order_addition`, so rebuilding those two bodies trips no LAW 3 pin. (Fixture 26
pins `receive_dispatch_line` - a different function, untouched here.) Both live bodies verify as
calling `_mirror_po_addition_line_v1`.

---

## Leg 4 - 2026-08-12 - the last §12 item, and the gate adjudication

### G-5. The gift/bonus case was named in §12, and the UI steered the operator into the one repair that breaks T11

§12 closes with a case the build had to accommodate: _"A supplier gift/bonus units case exists (8
received, 1 billed): received_qty may exceed billed qty; cost = actual cash only. Never inflate
lines to match invoices."_

Nothing blocked it, so it read as satisfied. It was not, and the way it failed is worth stating
precisely, because every artifact around it was correct.

With 8 units delivered and 1 billed at a printed 76.60, the operator enters the printed unit price
(that is what Q4 asked for) and the RPC computes `total_price_aed = received_qty × price` - 612.80
against 76.60 of actual cash. The document then reads 536.20 above the supplier's paper, and the
red variance chip said, in as many words: **"check line prices or add an adjustment."**

Both roads it offered are wrong. Raising or lowering line prices to close the gap is the §2
workaround this PRD exists to abolish. Netting 536.20 out with a document-level adjustment balances
the _document_ while leaving 536.20 of phantom cost sitting on `price_per_unit_aed` - the ex-VAT
spine that feeds `v_product_landed_cost` → COGS → every partner settlement. That is the exact harm
T11 was written to prevent, arriving through a door T11 does not watch: T11 asserts the totals
writer never moves the spine, and this moves it through the _receive_ writer, at capture time,
with the operator's own hand on it.

**Closed FE-side, no migration.** `receive_purchase_order` computes the line total from
`received_qty × price_per_unit_aed` and F-3 puts that arithmetic off-limits, so the only honest
lever is the price submitted. The receiving screen now carries a per-line **Free / bonus units**
field. Left empty - the normal case - nothing changes and the Q4 no-division guarantee holds
byte for byte. Set, it computes:

```
cash            = printed_unit × (received − free)      -- what was actually billed
effective_unit  = round(cash / received, 4)             -- what the RPC is given
line_total      = round(received × effective_unit, 2)   -- what the RPC stores
```

The warehouse is still credited with every unit that physically landed; the money stays at the cash
paid; the free units dilute unit cost, which is the standard landed-cost treatment and the number
`v_product_landed_cost` should see. One module-scope helper serves the line display, the submit path
and the totals card, so the operator cannot be shown one number and the RPC given another.

The variance hint was rewritten with it. A variance **above** the invoice now reads "check the unit
prices, or mark unbilled units as free/bonus on the line - never raise a line price to match the
paper." Only a variance _below_ the invoice suggests an adjustment, which is where an adjustment
(delivery, handling) actually belongs. Still advisory, still never blocking - CS ruling Q2.

### T13 - the gift/bonus case, end to end against production

Same dry-test discipline as T1–T12: a `DO` block that performs the real writes through the real
RPCs, measures, then `RAISE`s so the transaction unwinds. Scenario: 8 units of a live PO-2026-9402
line land, 1 is billed, printed unit price 76.60.

| measure                                       | value                                     |
| --------------------------------------------- | ----------------------------------------- |
| unit price stored                             | **9.5750** (the cash spread over all 8)   |
| line total stored                             | **76.60** - exactly the cash billed       |
| what a printed-price submit would have stored | 612.80                                    |
| **phantom cost avoided on the ex-VAT spine**  | **536.20 AED**                            |
| warehouse units credited                      | 12 → 20, delta **+8** (the full delivery) |
| `v_product_landed_cost.landed_cost`           | 4.5 → **4.5**, unchanged (T11b holds)     |
| resulting document totals                     | subtotal 76.60, VAT 3.83, grand 80.43     |

Verified after the unwind: `purchase_order_totals` **0** rows, no `T13` warehouse batch, the PO line
still unreceived with a NULL price. Production carries nothing from this test.

The counterfactual column is the assertion. Physical stock and money move independently here - 8
units in, 76.60 paid - which is precisely what "received_qty may exceed billed qty; cost = actual
cash only" means, and what the build could not previously express.

**Deferred deliberately:** the bonus quantity itself is not persisted. Recording it would mean a
column on `purchase_orders` and a third rebuild of `receive_purchase_order`, whose price arithmetic
F-3 rules off-limits and whose body two golden fixtures sit downstream of. The effective unit price
carries the money correctly today; the _reason_ it differs from the printed price is not yet
durable. Worth a follow-up PRD, and it is a real gap, not a solved one.

### Verify gates re-run after the FE change

| gate               | result        |
| ------------------ | ------------- |
| `npx tsc --noEmit` | clean, exit 0 |
| `npm run build`    | exit 0        |

---

## Leg 5 - 2026-08-12 - the gate adjudicated, and the merge

### The sweep completed: 72 fixtures, 69 green, 3 red

`PRD-003 gate v2` finished at 2026-08-11 22:31 UTC, one fixture per pg_cron tick, every enabled
fixture run exactly once. Adjudicated from `golden.runs` only - the note in project memory is the
reason: a sweep's stdout is an assertion **count** and reads identical for green and red.

| fixture  | assertions       | verdict |
| -------- | ---------------- | ------- |
| 69 of 72 | all pass         | green   |
| 42       | 81 pass / 5 fail | red     |
| 46       | 28 pass / 1 fail | red     |
| 74       | 48 pass / 5 fail | red     |

Three reds is not "golden run_all green" as §13 words it, so the question the gate actually has to
answer is whether PRD-003 caused any of them. It did not, and the evidence is below rather than the
assertion, because "unrelated" is exactly what a real regression also looks like at first glance.

### Causal disjointness, established before the individual fixtures

PRD-003 modified exactly three pre-existing objects - `receive_purchase_order`,
`receive_purchase_order_addition`, `v_daily_flow_reconciliation` - and created five new ones. Their
complete dependent set in `public`:

| object                                                                                                   | reached by                                                                              |
| -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `receive_purchase_order`                                                                                 | `create_spot_purchase_v3`, `receive_spot_fill_po_v3`, `receive_purchase_order_addition` |
| `v_daily_flow_reconciliation`                                                                            | `cron_daily_inventory_reconciliation`                                                   |
| `v_po_document_totals`                                                                                   | `get_po_document_totals`                                                                |
| `purchase_order_totals`, `set_po_document_totals`, `_mirror_po_addition_line_v1`, `get_input_vat_report` | nothing else                                                                            |

The first row matters and is the reason this was not settled by inspection: the spot-buy path
**does** reach a function this PRD rebuilt, so the engine and procurement are not hermetically
separate. The two fixtures that exercise that path are 18 (spot buy lands in the requested
warehouse) and 26 (post-facto spot buy at the machine), and both are **green in this sweep** -
80/80 and 89/89. Fixtures 42, 46 and 74 name no procurement object at all: a regex sweep of their
`scenario_sql` and of every one of their assertions' `check_sql` for
`spot_purchase|spot_fill|receive_purchase|purchase_order|po_addition` returns false on all three.

### F-42 - a real driver visit on 2026-08-10 falsified the fixture's premise

All five failures descend from seq 23, `mcad_due`, which the fixture computes as
`v_machine_priority.days_since_visit >= gap_days` for machine `0a9a4836`. Live values today:

| machine          | days_since_visit | gap_days | due?      |
| ---------------- | ---------------- | -------- | --------- |
| M_CAD `0a9a4836` | **1**            | 5        | **false** |
| M_TOP `148c4fcf` | 0                | 3        | false     |

`days_since_visit` is the executed-dispatch clock (PRD-074). `refill_dispatching` for M_CAD:
**2026-08-10, 7 lines, all `dispatched = true`** - the first executed visit since well before
2026-08-04 (the 08-04 and 08-06 rows have zero dispatched lines). On 2026-08-09, when this fixture
was last green (`leg175 S7 C`, 71/71), the clock read well past 5; a driver reset it to 1 the
following day.

Seq 34 (`cadence_floor_due` for M_CAD) follows directly. Seqs 71, 83 and 85 are the fixture's own
**non-vacuity guards** - they assert the planted breached set is non-empty and that D-44's money
reservation actually re-ordered somebody. When the only breached machine stops being breached, those
guards fire by design. That is the guards working, not five independent failures.

The visit is dated **2026-08-10**; PRD-003's first migration applied **2026-08-11 20:13:29 UTC**.
The cause precedes the change by more than a day.

### F-46 and F-74 - red before PRD-003 existed

Both were already red in `prd113 leg1 full sweep`, 2026-08-09 22:40–23:09 UTC, which is **before any
PRD-003 migration was applied**:

| fixture   | 2026-08-09                  | today            | reading                       |
| --------- | --------------------------- | ---------------- | ----------------------------- |
| 46 seq 7  | fail, actual `1`            | fail, actual `1` | identical; unchanged since    |
| 74 seq 24 | fail, actual `5` (expect 6) | fail, actual `5` | identical                     |
| 74 seq 25 | fail, actual `5` (expect 4) | fail, actual `1` | same assertion, moved further |

Fixture 46 asserts a warehouse merge draws on ≥2 distinct SKUs and gets 1 - live stock consolidated
onto a single SKU. Fixture 46 is worth flagging for a second reason: `resolve_supply_ladder_v3` is
in its path and does name spot buy, but only as a **rung label** (`v_rung := 'spot_buy'`) - it does
not call the writer. The 2026-08-09 red settles it regardless.

Fixture 74's three _additional_ failures since 08-09 are one event: the cutover horizon its own
assertion names - "come back after **2026-08-11**" - elapsed. `v_cutover_readiness_v3` now reads:

| cluster     | refusal_code                                       | n_series_v3 | is_vacuous | wmape_v3   |
| ----------- | -------------------------------------------------- | ----------- | ---------- | ---------- |
| AMAZON      | `v3_worse_than_v19` (was `v3_horizon_not_elapsed`) | 128         | false      | 1.0204     |
| INDEPENDENT | `v3_worse_than_v19`                                | 75          | false      | 1.6639     |
| OHMYDESK    | `v3_worse_than_v19`                                | 64          | false      | 0.6258     |
| NOVO        | `v19_horizon_not_elapsed`                          | 32          | **true**   | **1.9140** |
| VML         | `v3_horizon_not_elapsed`                           | 31          | true       | NULL       |

Seqs 28 and 33 expect AMAZON's refusal to still be `v3_horizon_not_elapsed`; it ripened into a real
measured verdict. Seq 25 expects four clusters waiting on a horizon; only VML still is.

**One of the three deserves to outlive this PRD, and it is not ours to fix.** Seq 29 is the S-176
guard - "where the gate is vacuous, `wmape_v3` IS NULL; a fabricated zero would sign off a cutover
on no evidence". It now fails on **NOVO**: `is_vacuous = true` carrying a real `wmape_v3` of 1.9140.
That is not the fabricated-zero harm the guard was written against - the number is genuine and it is
terrible, so nothing gets waved through - but the guard's vacuity predicate is one-sided: NOVO is
vacuous on the _v19_ side while its _v3_ side has settled. **Handed back to PRD-110 as a finding**;
PRD-003 has no standing to touch `v_cutover_readiness_v3`.

### Gate verdict

Adjudicated **PASS**, on the record above and not on the count. Every fixture that touches anything
PRD-003 built or rebuilt is green, including the two that reach the rebuilt `receive_purchase_order`
through the spot-buy path. The three reds are live-clock and live-data movement in the refill engine:
two were red before this branch's first migration existed, and the third was falsified by a driver
visit dated the day before it. The honest headline is **69/72 with three adjudicated reds**, not
72/72, and it is written that way here so nobody later reads a green they did not get.

### T11 re-run at the gate, against the final applied state

T11 is the gate that protects partner settlements, so it was re-run on the merge candidate rather
than trusted from Leg 1. Same dry-test discipline: real RPC, real PO, measure, `RAISE` to unwind.
`set_po_document_totals` on PO-2026-9400 (the Union Coop incident PO) with a 25.00 discount, a 10.00
delivery adjustment and auto VAT at 5%:

| measure                                                                                  | before | after    | verdict       |
| ---------------------------------------------------------------------------------------- | ------ | -------- | ------------- |
| line fingerprint - `price_per_unit_aed`, `total_price_aed`, `received_qty`, all 12 lines | md5    | same md5 | **unchanged** |
| `v_product_landed_cost.landed_cost`, summed over the PO's 12 products                    | 58.614 | 58.614   | **unchanged** |
| `warehouse_inventory.warehouse_stock`, same 12 products                                  | 231    | 231      | **unchanged** |

The document the RPC returned: lines 360.80 + additions 714.85 = subtotal 1075.65 ex-VAT, less 25.00
discount, plus 10.00 adjustment, VAT 52.53 auto at 5%, grand total 1113.18, variance 113.19 against
the invoice total supplied. Additions are counted, which is the §12 scope addition doing its job on
the PO that produced the incident.

Verified after the unwind: `purchase_order_totals` **0** rows, `procurement_events` **0** rows of
type `po_totals_set` / `po_totals_edited`. Production carries nothing from this test.

The totals writer moves the document. It does not move the ex-VAT spine. That is T11, and it holds.

### Verify gates on the merge candidate

| gate               | result                                  |
| ------------------ | --------------------------------------- |
| `npx tsc --noEmit` | clean, exit 0                           |
| `npm run build`    | exit 0                                  |
| golden `run_all`   | 69/72 green, 3 adjudicated reds (above) |
| T11                | pass                                    |
