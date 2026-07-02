# PRD-043 - Picker v10 -> v11: enforce the VOX Wed/Fri calendar gate

**Status:** Shipped (`pick_machines_for_refill` v11 calendar gate applied; 2 MIGRATIONS_REGISTRY entries + PROD-SYNC-PRD042-043-LOG.md). PRD-071 sweep 2026-07-02.
**Owner:** CS (cyrilsem@gmail.com)
**Created:** 2026-06-20
**Depends on:** picker v10 (live), `v_machine_priority` (Article 16 health view), PRD-035 WS-E (Saturday delivery-day guard, unchanged).
**Severity:** Medium. Not a data-integrity bug. It mis-routes the daily pick: VOX machines get serviced off-schedule and consume cap slots that should go to main-track machines.

## 0. Why

The fleet runs VOX venues on a **Wednesday/Friday service calendar**. v10 was meant to enforce that. It half does.

v10 computes the gate correctly:

```sql
v_is_vox_day := EXTRACT(DOW FROM p_plan_date) IN (3, 5);  -- Wed=3, Fri=5
```

On Wed/Fri it runs a dedicated VOX branch (sweep the VOX venue + the 3 nearest non-VOX neighbours, reasons `vox_calendar` / `vox_day_nonvox_nearest`). Correct.

The gap is the **normal-day branch**. Its primary selection has no venue filter:

```sql
ranked_primary AS (
  SELECT sc.*, ROW_NUMBER() OVER (ORDER BY sc.p_score DESC, sc.units_last_7d DESC, sc.official_name) AS pick_rn
  FROM scored sc WHERE sc.p_tier = 'P1_RESTOCK'        -- VOX not excluded
),
primary_picks AS (SELECT ... FROM ranked_primary WHERE pick_rn <= p_max_total)
```

The only `venue_group IS DISTINCT FROM 'VOX'` exclusion in the whole branch sits in `sibling_ranked` (the venue-sibling expansion), not in `ranked_primary`. So on a non-VOX day the primary pick still ranks every P1 machine fleet-wide, VOX included.

And VOX machines score highest, so they crowd the top of the cap.

**Observed (plan_date Sun 21 Jun 2026, cap 8):**

| #   | Machine               | Track | p_score     | runway        | picked           |
| --- | --------------------- | ----- | ----------- | ------------- | ---------------- |
| 1   | ACTIVATE-2005-0000-W0 | vox   | 137         | 8.7d          | yes (off-day)    |
| 2   | VOXMCC-1005-0201-B0   | vox   | 83          | 4.7d          | yes (off-day)    |
| 3   | AMZ-1029-3003-O1      | main  | 70          | 7.0d          | yes              |
| ... | ...                   | main  | ...         | ...           | ...              |
| -   | WPP-1002-4300-O1      | main  | (below cut) | 7.6d, 158u/7d | **squeezed out** |

Two consequences:

1. **Off-schedule VOX service.** Sunday is not a VOX day, yet two VOX machines were routed. Next real VOX day was Wed 24 Jun.
2. **Cap starvation of main track.** VOX took 2 of 8 slots, helping push WPP-1002 (3rd-highest velocity in the fleet, 7.6d runway) off the route.

The intent ("VOX on Wed/Fri") was wired as a switch that turns the VOX sweep **on** for Wed/Fri, but never turns VOX **off** in the normal-day primary pick.

## 1. The change (one guard, plus a decided override)

Add the venue gate to `ranked_primary` in the normal-day branch:

```sql
FROM scored sc
WHERE sc.p_tier = 'P1_RESTOCK'
  AND ( v_is_vox_day
        OR sc.venue_group IS DISTINCT FROM 'VOX'
        OR <emergency override, see 2> )
```

On Wed/Fri the branch is not reached anyway, so the `v_is_vox_day` disjunct is belt-and-suspenders. Net effect: on non-VOX days, VOX machines are excluded from the primary pick (unless the override fires). `sibling_ranked` is unchanged (already excludes VOX). Cap then flows to main-track machines, which fixes the WPP-class squeeze-out as a side effect.

Version bump `pick_machines_for_refill` v10 -> v11 (forward `CREATE OR REPLACE`, Hard Rule 6 + 10: Cody review, CS green light).

## 2. The one decision for CS - strict vs emergency override

A strict gate means a VOX machine that stocks out before its next scheduled day waits anyway. On 21 Jun, VOXMCC-1005 was at 4.7d runway (would reach Wed 24 Jun, barely) and ACTIVATE-2005 already had 3 empty shelves and an expired SKU. So a pure strict rule can strand a genuinely critical VOX machine for up to 3 days.

**Option A - strict.** VOX is only ever picked on Wed/Fri. Simplest, fully honours the calendar. Critical VOX machines wait.

**Option B - strict + narrow emergency override (recommended).** VOX excluded on non-VOX days, except a machine that will not survive to its next scheduled VOX day:

```sql
OR ( sc.venue_group = 'VOX'
     AND COALESCE(sc.runway_days, 999) < public.days_until_next_vox_day(p_plan_date) )
```

where `days_until_next_vox_day` returns the day count from `p_plan_date` to the next DOW in (3,5). Such a pick is tagged with a distinct reason `vox_emergency_offday` so it is visible in the advisory and on the route, and it still counts against the cap-8.

Recommendation: **Option B**, runway-based predicate as written. The one thing to confirm is the predicate: runway-only, or also admit `empty_shelves_count > 0` / `expired_skus_now > 0`. Default keeps it tight (runway-only) to avoid VOX leaking back in on a single empty shelf.

## 3. Tests (replay, BEGIN..ROLLBACK, both calendar cases)

| #   | Test                               | Expected                                                                                                                                                         |
| --- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| V1  | non-VOX day, strict path           | pick a Sunday/Mon/Tue/Thu plan_date: zero `venue_group='VOX'` rows in `machines_to_visit` (Option A), or only `vox_emergency_offday`-tagged ones (Option B).     |
| V2  | cap reclaimed                      | with VOX removed from 21 Jun, the freed slots go to the next main-track P1 machines by p_score; WPP-1002 (or current equivalent) now makes the route.            |
| V3  | VOX day unchanged                  | pick a Wed (24 Jun) and Fri (26 Jun): VOX sweep branch still fires, `vox_calendar` + `vox_day_nonvox_nearest` reasons intact, counts match v10.                  |
| V4  | emergency override (Option B only) | a synthetic VOX machine with `runway_days < days_until_next_vox_day` on a non-VOX day is picked and tagged `vox_emergency_offday`; one with ample runway is not. |
| V5  | cap + siblings                     | total picked <= `p_max_total` (8); `sibling_ranked` still excludes VOX; sibling count <= `p_max_siblings`.                                                       |
| V6  | Saturday guard                     | PRD-035 WS-E still returns no pick on a Saturday plan_date (unchanged).                                                                                          |
| R1  | regression                         | VOX-day branch output byte-identical to v10 for 24 Jun and 26 Jun; non-VOX-day main-track ordering otherwise unchanged.                                          |

## 4. Phasing / gates

- **P0** Option A vs B decision from CS; if B, Dara adds the tiny `days_until_next_vox_day(date)` helper (IMMUTABLE, no table access) for Cody review.
- **P1** picker v10 -> v11 forward rewrite (single guard in `ranked_primary`, plus override disjunct if B); Cody verdict (SECURITY DEFINER canonical writer, Hard Rule 6); replay V1-V6 + R1; STOP for CS; apply on "apply P1".
- No change to `build_draft_for_confirmed`, the 8pm cron, the engines, or stitch. The advisory will simply stop showing off-day VOX rows.

## 5. Cross-ref / notes

- Stale docs to fix on apply: boonz-master-3 skill version map still says picker v8; memory said v9; live is v10 -> bump to v11. Update the engine-version table in the same change.
- Connected symptom: the WPP-1002 squeeze-out flagged in the 21 Jun advisory review is a downstream effect of this cap starvation, not a separate scoring bug.
- Does not touch the Saturday delivery-day guard (PRD-035 WS-E) or the VOX-day sweep math.
