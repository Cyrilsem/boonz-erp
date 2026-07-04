# PRD-075: Priority chapter close (repurpose grace, visit truth, core chip split)

Status: SHIPPED 2026-07-04 (WS-A/B/C applied, fleet-diff proofs green, guard v2 0 diffs; see PRD-075-EXECUTION-LOG.md). Chapter closed.
Owner: CS. Mode: AUTO with hard gates. Closes the P1/P2 workstream opened by the eligibility incident (PRD-073) and the single-source consolidation (PRD-074).

## The three rulings

1. Repurposed-but-Active x3 (ACTIVATE-2005, IFLYMCC-1024, MPMCC-1054): CS chose to un-blind them. Chat attempt to NULL repurposed_at was correctly REJECTED by chk_repurpose_consistency (repurposed_at is permanent history when previous_location is set; ACTIVATE-2005 was MPMCC-2005). Therefore: fix eligibility, not history.
2. VOX visit truth: logged manual/field refills COUNT as visit evidence in the canonical clock.
3. Core chip split: expose the four s_* terms on v_machine_priority (the PRD-074 carry-forward).

## Workstreams

### WS-A: Repurpose grace window in eligibility

1. Dara: v_live_shelf_stock is_eligible_machine becomes: adyen_status='Online today' AND adyen_inventory_in_store='Live' AND (repurposed_at IS NULL OR repurposed_at < now() - make_interval(days => grace)). grace from a new pick_urgency_params.repurpose_grace_days (default 30). Rationale: the exclusion exists to keep machines-in-transition out of grading; it must not permanently brand relocated machines.
2. Cody review: v_live_shelf_stock has many consumers (v_shelf_sales_identity, v_machine_health_signals, shelf CTEs, FE). Enumerate consumers and confirm the column change is additive in behavior only for the repurposed-old case.
3. T: the 3 machines gain nonzero grade counts in v_machine_priority; v_machine_eligibility_drift returns zero rows (MPMCC-1058 'Pending Setup' stays excluded, legitimate); no other machine's eligibility flips.

### WS-B: Manual refills count as visits (the VOX fix)

1. Locate the canonical manual-refill event source (log_manual_refill writer from PRD-036/040; find its table). v_machine_health_signals last_visit becomes GREATEST of: executed dispatch evidence (unchanged definition) and latest manual refill log event for the machine.
2. get_machine_health v3 inherits automatically (it passes the signals field through; verify no cached copy).
3. METRICS_REGISTRY: update the days_since_visit definition row: executed dispatch OR logged manual refill.
4. FieldCapturePanel minimal hardening so the VOX venue team can actually log: machine-scoped product list (only pods on that machine's shelves, not the all-300 picker), default qty = fill-to-cap, offline-tolerant submit. Do NOT redesign; smallest usable pass. (Known weak-UX follow-up from PRD-040 Track C.)
5. T: insert a test manual-refill log row for a VOX machine in a rolled-back txn; days_since_visit resets in the same txn; consistency checker still zero diffs.

### WS-C: Split the lumped core chip

1. v_machine_priority: add s_runout, s_capacity, s_expiry, s_stale as output columns (values already computed in mscore CTE; pure exposure, no logic change). This is the sanctioned modification of the view; PRD-074's freeze was scoped to that PRD.
2. get_machine_health urgency_breakdown: replace the lumped core entry with the four real terms (label + pts each, weights applied). Chip sum must still equal urgency exactly.
3. FE renders the richer breakdown verbatim (no new math).
4. Extend check_priority_surface_consistency() to the four new fields.
5. T: chip sum == urgency fleet-wide; view md5 change is EXPECTED here and must be recorded (before/after) in MIGRATIONS_REGISTRY; p_tier and urgency values byte-identical for every machine before vs after (exposure-only proof).

## Gates

engine_add_pod, engine_swap_pod, pick_machines_for_refill md5 byte-identical. v_machine_priority p_tier/urgency values must not change (WS-C is column exposure only; prove with a before/after full-fleet diff). v_live_shelf_stock change proven with full-fleet before/after eligibility diff: only the 3 named machines flip. BEGIN..ROLLBACK for every write. Params in pick_urgency_params. Build green. Registries + CHANGELOG + METRICS_REGISTRY + execution log. Commit and push; main == origin/main.

## Acceptance

- The 3 machines grade and can reach P1 on merit; relocation history intact.
- A logged VOX venue-team refill resets the visit clock; field panel usable on a phone.
- Chips show runout/capacity/expiry/stale/empty/lowfill as separate honest terms summing to urgency.
- Consistency checker zero diffs; drift monitor zero rows; no tier changed by WS-C.

## Rollback

WS-A: set repurpose_grace_days to 0 (restores strict behavior without a migration). WS-B: re-apply prior signals body (_HELD). WS-C: prior view body (_HELD); breakdown falls back to lumped core if s_* columns absent (FE renders whatever list arrives).
