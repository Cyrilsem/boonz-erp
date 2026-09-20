-- ONE-LOOP-3 Job 4 (get_advisors, performance): unindexed_foreign_keys on
-- two tables touched tonight. substitution_rules gained its writer RPCs
-- (add/deactivate_substitution_rule) tonight; machines_to_visit is now
-- written far more heavily by pick_machines_for_refill v12's three-phase
-- cluster fill.
CREATE INDEX IF NOT EXISTS idx_machines_to_visit_machine_id
  ON public.machines_to_visit (machine_id);
CREATE INDEX IF NOT EXISTS idx_substitution_rules_when_pod_product_id
  ON public.substitution_rules (when_pod_product_id);
CREATE INDEX IF NOT EXISTS idx_substitution_rules_then_pod_product_id
  ON public.substitution_rules (then_pod_product_id);
