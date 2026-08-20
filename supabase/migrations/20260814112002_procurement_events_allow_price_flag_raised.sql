-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-022: procurement_events.event_type CHECK += 'price_flag_raised', the event the new
-- procurement_price_sync_and_flag trigger writes when it stamps a flag. DROP + ADD pattern, per
-- docs/architecture/MIGRATIONS_REGISTRY.md line 5419.
--
-- Reconstructed by taking the CURRENT live constraint (pg_get_constraintdef, 2026-08-20) and
-- removing 'price_flag_reviewed', which docs/architecture/MIGRATIONS_REGISTRY.md line 5435 confirms
-- was added a day later by po_pricing_status_v1 (the review_price_flag_v1 RPC's event). Everything
-- else in the list predates this migration. GREEN: the widening pattern and the full prior value
-- list are both directly recoverable, only the one later addition needed subtracting.

alter table public.procurement_events
  drop constraint if exists procurement_events_event_type_check;

alter table public.procurement_events
  add constraint procurement_events_event_type_check
  check (event_type = any (array[
    'po_created', 'po_line_edited', 'lines_appended', 'task_assigned',
    'task_acknowledged', 'task_collected', 'task_cancelled', 'task_pending',
    'task_reopened', 'goods_received', 'line_not_purchased',
    'spot_purchase_created', 'spot_purchase_task_autoclosed',
    'post_facto_fill_recorded', 'post_facto_fill_received',
    'po_totals_set', 'po_totals_edited', 'po_addition_line_mirrored',
    'price_flag_raised'
  ]));
