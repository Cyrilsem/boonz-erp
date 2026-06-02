# Stax spec — Priority reweight + VOX parallel track (FE surfaces)

**Date:** 2026-06-02
**Origin:** CS request — "higher weight on velocity & shelves; empty shelves = no-go top priority; dead items + long refill = priority 2; VOX on a parallel track below the non-VOX list with a small dashed separator."
**Backend status:** Picker `pick_machines_for_refill` already shipped as **v7** (`phaseF_picker_v7_velocity_shelf_reweight`, applied to prod 2026-06-02). This spec covers the **FE surfaces** that still need to match.

---

## Two surfaces, two data sources

| Surface | Component | Data source | Status |
|---|---|---|---|
| Refill Planning machine list | `RefillPlanningTab.tsx` | `machines_to_visit` (picker v7) | ✅ Backend done; reads new `service_track` + `priority_tier` once FE references them |
| **Stock Snapshot — Machine health "Priority" sort** | `src/app/(app)/refill/page.tsx` | `get_machine_health()` + client-side `refillUrgency()` | ❌ This is the screen CS was looking at. Needs the change below. |

The Stock Snapshot card grid does **not** read the picker. It calls `get_machine_health()` and ranks the whole fleet client-side via `refillUrgency()`. So the picker reweight alone does not change that screen.

---

## The new model (must match picker v7)

Two tiers. VOX is a separate track shown **below** the main track with a dashed separator.

**P1_RESTOCK** (the sellers running dry / empty — top priority):
- ANY empty shelf → hard top. Score `50 + 12 × (empties − 1)`.
- Selling machine low runway: `units_7d ≥ 20 AND runway < 14d`, or `runway < 7d` for anything. Score 35 / 28 / 25 / 12 banded (see formula).
- Shelf under 25% on a seller (`units_7d ≥ 15`): `+8 each`, cap 24.
- High-velocity bonus (`units_7d ≥ 50`): `+10`.

**P2_MAINTAIN** (maintenance — never outranks a stockout; small weights):
- Dead slots `≥ 15%` → +8, `≥ 30%` → +15.
- Long refill gap: `days_since_visit ≥ 21` → +10, `≥ 14` → +6, `≥ 10` → +3.
- Expired stock now → +8 (deliberately demoted; expiry is handled on the spot).
- Active intent / pending swap → +5.

**Tier assignment:**
```
P1_RESTOCK  if empty ≥ 1
            OR runway < 7
            OR (runway < 14 AND units_7d ≥ 20)
            OR (under25 ≥ 1 AND units_7d ≥ 20)
P2_MAINTAIN else if dead% ≥ 15 OR days_since_visit ≥ 14 OR expired_now ≥ 1 OR intent > 0
SKIP        else  (not shown / bottom)
```

---

## Recommended implementation — keep ONE source of truth

Do **not** re-encode the weights in TypeScript and let them drift from the SQL picker. Instead extend the read-only helper so FE just sorts.

### 1. Backend — extend `get_machine_health()` (read-only; Cody class (c), light review)

Add three columns to its `RETURNS TABLE`, computed with the **same** v7 expressions:
- `service_track text` — `CASE WHEN venue_group = 'VOX' THEN 'vox' ELSE 'main' END`
- `priority_tier text` — `'P1_RESTOCK' | 'P2_MAINTAIN' | 'skip'` per the tier assignment above
- `priority_score numeric` — the weighted sum above

Field mapping inside `get_machine_health()` (it already exposes these): `slots_at_zero` → empty; `slots_below_25pct − slots_at_zero` → under25 (non-empty); `daily_velocity × 7` → units_7d; `days_until_empty` → runway; `dead_stock_count`/slot count → dead%; `days_since_visit`; `expired_units` → expired_now; `pending_swap_count` → intent proxy. Reuse the exact CASE/threshold constants from `phaseF_picker_v7_velocity_shelf_reweight` so the card grid and the picker never disagree. **`get_machine_health()` is read-only — confirm it stays `SECURITY INVOKER` (or DEFINER read-only with no writes) and route the change through Cody (Article: read-only DEFINER / Article 12 forward-only).**

### 2. FE — `src/app/(app)/refill/page.tsx`

**a. Type** — add to `MachineHealth`:
```ts
service_track: "main" | "vox";
priority_tier: "P1_RESTOCK" | "P2_MAINTAIN" | "skip";
priority_score: number;
```

**b. Replace `refillUrgency(m)`** — return `m.priority_score` straight from the RPC (delete the local weighting), so the card color scale and sort both key off the backend score.

**c. Sort (priority mode)** — order by track, then tier, then score:
```ts
case "priority":
  sorted.sort((a, b) =>
    Number(a.service_track === "vox") - Number(b.service_track === "vox")   // main first
    || tierRank(a.priority_tier) - tierRank(b.priority_tier)                 // P1 before P2
    || b.priority_score - a.priority_score
  );
  break;
// tierRank: P1_RESTOCK=0, P2_MAINTAIN=1, skip=2
```
(Keep the existing "excluded always last" final pass.)

**d. Dashed separator** — when rendering the card grid in priority mode, insert a full-width divider row between the last `service_track==='main'` card and the first `service_track==='vox'` card:
```tsx
{sortedMachines.map((m, i) => {
  const prev = sortedMachines[i - 1];
  const boundary = sortBy === "priority"
    && prev?.service_track === "main" && m.service_track === "vox";
  return (
    <Fragment key={m.machine_id}>
      {boundary && (
        <div className="col-span-full my-2 flex items-center gap-2 text-xs text-neutral-400">
          <span className="flex-1 border-t border-dashed border-neutral-300" />
          VOX — refilled daily on the spot
          <span className="flex-1 border-t border-dashed border-neutral-300" />
        </div>
      )}
      {/* existing card */}
    </Fragment>
  );
})}
```
(Grid is `grid-cols-*`; `col-span-full` makes the separator span the row. Only show it in `priority` sort mode.)

**e. Legend pills (priority mode)** — replace the urgency buckets with two: `P1 Restock` (count of main P1) and `P2 Maintain` (count of main P2); optionally a muted `VOX (n)` pill.

---

## Acceptance checks
- In Priority sort, AMZ-1038 (3 empty shelves, 81 u/wk) sits at the very top of the main group.
- Zombies (GRIT, HUAWEI, WAVEMAKER — <50% fill but 180d+ runway) fall into P2, below every P1.
- Expired-only machines (AMZ-1057, AMZ-1068) sit at the bottom of P2.
- All VOX cards render below the dashed separator regardless of their score.
- Card-grid order matches the picker's `machines_to_visit` order for the same date (one source of truth).

## Review path
`get_machine_health()` change → Cody (read-only helper). FE change → Stax self-review + Cody only if it adds a direct protected-table write (it does not; it's read + sort). No Dara change (no schema).
