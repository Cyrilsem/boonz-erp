# Claude Code /goal Command

Copy and paste the block below into Claude Code CLI:

```
/goal Implement two PRDs for the boonz-erp Next.js app. Read both PRDs first, then execute.

## PRD 1: Dark Mode Fix (PRD-UI-001) — Priority: do this first, it's 3 files
Read: docs/prds/ui/PRD-UI-001-dark-mode-contrast-fix.md

Changes:
1. src/app/globals.css — Remove the @media (prefers-color-scheme: dark) block entirely. Add `color-scheme: light;` to :root. Keep everything else.
2. src/app/layout.tsx — Add <meta name="color-scheme" content="light" /> in the <head>.
3. tailwind.config.ts — Ensure darkMode is set to 'class' (not 'media'). If no darkMode key exists, add it.

Verify: Run `npx next build` to confirm no build errors.

## PRD 2: Engine v11 Refill Logic (PRD-010) — Backend RPCs in Supabase
Read: docs/prds/refill-pipeline/PRD-010-engine-v11-floor-swap-capacity.md

This PRD modifies 3 Supabase RPCs. Generate SQL migration files in supabase/migrations/ with timestamp prefix format YYYYMMDDHHMMSS.

### AC#1: Signal-aware performance floor in engine_add_pod
Find the performance_floor logic in the engine_add_pod function. Currently it applies a uniform floor regardless of signal. Replace with a signal-based lookup:
- STAR/DOUBLE DOWN: floor = 0.80 * max_capacity
- KEEP GROWING: floor = 0.70 * max_capacity
- KEEP: floor = 0.60 * max_capacity
- WATCH: floor = 0.40 * max_capacity
- RAMPING: floor = 0.50 * max_capacity
- WIND DOWN: floor = 0 (velocity target only, set clamp_reason to 'velocity_target')
- ROTATE OUT/DEAD: floor = 0 (should not refill, only swap/remove)
When the floor activates and signal is not WIND DOWN/ROTATE OUT/DEAD, set clamp_reason to 'signal_floor'.

### AC#2: Duplicate swap guard in engine_swap_pod
In the autonomous Pearson Pass 2 loop, before committing an ADD_NEW row:
a) Check if the candidate pod_product_id already exists on another shelf of the same machine in the current draft (SELECT from pod_refill_plan WHERE plan_date/machine_id match AND action='ADD_NEW' AND pod_product_id=candidate). If yes, skip to next Pearson candidate.
b) Check if the target shelf_id has a pending planned_swap (SELECT FROM planned_swaps WHERE machine_name matches AND status='pending'). If yes, skip autonomous substitution for that shelf — the strategic swap takes priority.

### AC#3: Visual-fill minimum for healthy products in engine_add_pod
After computing velocity_target, for signals in (STAR, DOUBLE DOWN, KEEP GROWING, KEEP):
  visual_floor = CEIL(max_capacity * 0.50)
  final_target = GREATEST(velocity_target, visual_floor)
  refill_qty = GREATEST(final_target - current_stock, 0)
When visual_floor > velocity_target and this activates, set clamp_reason to 'visual_fill_minimum'.

### AC#4: Capacity mismatch warnings in engine_finalize_pod
At the end of finalize, build a JSONB array of warnings where a product with signal in (STAR,DOUBLE DOWN,KEEP GROWING) sits on a shelf with max_capacity<=14 AND clamp_reason='capped_by_max', AND the same machine has a shelf with max_capacity>=20 occupied by signal in (WIND DOWN,ROTATE OUT,DEAD,WATCH). Include: machine_name, product names, shelf codes, capacities, velocities. Store in the function's return diagnostics object under key 'capacity_mismatch_warnings'.

### AC#5: Auto-close executed planned_swaps in pick_machines_for_refill
At the start of the picker, query planned_swaps WHERE status='pending'. For each, check v_live_shelf_stock: if add_pod_product is present on the machine AND remove_pod_product is absent from its original shelf, UPDATE planned_swaps SET status='completed', completed_at=now(), completed_by='auto_detect'.

## Constraints
- Do NOT modify any table schemas. All changes are RPC logic only (except the migration file for the RPC rewrites).
- Run `npx next build` after the UI fix to verify.
- Write each SQL migration as a separate file with a descriptive name.
- After writing migrations, show me the diff summary before I apply.
```
