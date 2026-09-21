# PRD-126 — Picker brain: an optimal P1 / P2 list

**Owner:** CS
**Written:** Monday 14 September 2026, late
**Status:** ready to build, inside the overnight loop

---

## 1. Problem

The tier a machine gets today is an OR of hard triggers, and three of them fire with no
regard to whether the machine sells anything:

| Trigger              | Param                      | Effect on 14 Sep                                                     |
| -------------------- | -------------------------- | -------------------------------------------------------------------- |
| 2 or more empty rows | `p1_holes_min = 2`         | GRIT (1.7/day, 52 d runway) is P1. WPP, refilled that morning, is P1 |
| 1 empty A or B lane  | `p1_empty_ab_min = 1`      | ALJLT (2.7/day, 39 d runway) is P1                                   |
| 14 days since visit  | `stale_override_days = 14` | JET (1.1/day, 70% full) is P1                                        |

So the P1 list on 14 Sep had 14 machines, and four of them were Zombies or Kill Candidates
sitting next to AMZ-1038 at 39 a day with 3 days of stock. The score column already knew
the difference (48.6 vs 23.9 vs 16.7). The tier label threw it away.

Two more faults in the same view:

- The score is in **units**. A lane of Aquafina at 1 AED and a lane of Barebells at 12 AED
  weigh the same. The list should be ordered by **money at risk**, not units.
- The picker ignores **geography**. It picks 8 machines by score with no notion that
  ACTIVATEMCC, MPMCC and IFLY are one car park and AMZ-1029 and AMZ-1038 are one building.

## 2. Goal

One score per machine that answers "how much revenue do we lose if we do not visit in the
next 3 days", a tier that is a function of that score **and** velocity, and a picker that
fills two cars by cluster.

## 3. Requirements

### R1. Revenue-weighted lane risk

For every lane: `lane_risk = daily_revenue_30d × max(0, horizon − runway_days)` where
`horizon = 3`, `runway_days = current_stock / daily_velocity_30d`, and `daily_revenue =
daily_velocity × actual_selling_price`. A lane that will not run out inside the horizon
contributes zero. Sum per machine into `s_runout_aed`.

### R2. Gap that only counts sellers

`s_gap_aed = Σ over lanes with velocity ≥ 1 of (max_stock − current_stock) × price ×
min(1, velocity / 3)`. Empty lanes on dead products contribute nothing to the tier. They
still appear as a count for the assortment review, which is a different job.

### R3. The score

`p_score = s_runout_aed + 0.5 × s_gap_aed + expiry_penalty + stale_penalty` where
`expiry_penalty = 2 × value of units expired on shelf + 1 × value expiring within 3 days`
and `stale_penalty = daily_revenue × max(0, days_since_visit − 10)`, capped at one day's
revenue. All in AED. All params in `pick_urgency_params`, replacing the unit-based weights.

### R4. Tiers

| Tier         | Rule                                                                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P1**       | expired units on shelf > 0, **or** a hero lane (velocity ≥ 3) with runway < 3 days, **or** `p_score ≥ p1_threshold_aed` **and** machine velocity ≥ 3/day |
| **P2**       | `p_score ≥ p2_threshold_aed`, **or** any lane with velocity ≥ 1 empty, **or** days_since_visit ≥ 14                                                      |
| **P3**       | everything else                                                                                                                                          |
| **cooldown** | visited yesterday or today: capped at P2 unless expired > 0                                                                                              |

A machine labelled Zombie or Kill Candidate never reaches P1 unless it has expired stock.
The point of a Zombie is that we stop spending on it.

Initial thresholds: `p1_threshold_aed = 150`, `p2_threshold_aed = 50`. Backtest both against
the last 30 days of actual picks and stock-outs and tune before the first live run.

### R5. The picker fills cars by cluster

`pick_machines_for_refill` v12 takes `p_cars int` and `p_per_car int` (2 and 8). It ranks by
`p_score`, then for each car it seeds with the highest unpicked P1 and fills the car with the
highest-scoring machines that share its `r_cluster` (`venue_group`, then `building_id`)
before crossing to another cluster. A P1 machine is never left unpicked while a P2 from the
same cluster is picked. Output includes `car_no` on `machines_to_visit`.

### R6. What the screen shows

The Machine Health card shows `p_score` in AED with the three biggest contributors named
(runout / gap / expiry / stale), the tier, the car assignment, and the velocity. Sort by
priority orders by `p_score`. The label "Zombie" stays; it is a strategy label, not a
refill signal.

### R7. Do not touch

`service_model`, `svc_track` and the T5 split from 14 Sep stay as they are. The partner-
filled kiosks stay excluded. The eight Boonz-filled VOX machines stay on the main track.

## 4. Acceptance criteria

On 14 September's data, before any refill:

| #   | Criterion                                                                                                                                                                                |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | AMZ-1038 and AMZ-1029 are the top two by `p_score`                                                                                                                                       |
| A2  | GRIT, WPP, ALJLT, JET are not P1                                                                                                                                                         |
| A3  | ACTIVATEMCC is P1 (1 empty shelf, hero runout, 9/day)                                                                                                                                    |
| A4  | NOVO, VML-1003, VML-1004, USH, MINDSHARE, WAVEMAKER, WPP, visited that day, are capped at P2                                                                                             |
| A5  | The two-car pick puts the Mirdif machines on one car and the AMZ machines on the other without being told                                                                                |
| A6  | P1 count on 14 Sep is between 5 and 8, and every one of them has velocity ≥ 3 or expired stock                                                                                           |
| A7  | A 30-day backtest lists every stock-out (a hero lane at zero on a WEIMI snapshot) and whether the machine was P1 the day before. The new rule must catch at least as many as the old one |
