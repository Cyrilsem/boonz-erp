# Machine Modes

## Mode parameters

| Mode         | days_cover | floor_qty | When                                   |
| ------------ | ---------- | --------- | -------------------------------------- |
| NORMAL       | 21         | 4         | Default for VOX + high-traffic         |
| CONSERVATIVE | 21         | 3         | Non-VOX office/coworking, low presence |
| SUMMER       | 7          | 6         | VOX entertainment May–Sep              |
| RAMP-UP      | 10         | 5         | New machines < 30 days data            |

## Current default

CONSERVATIVE — applies to all non-VOX machines unless overridden.

## Machine health adjustments (apply after mode params)

| Health label | Adjustment                                   |
| ------------ | -------------------------------------------- |
| Star (🟩)    | Push to target, no cap                       |
| At Risk      | Cap target at 90% of max_stock               |
| Zombie (🟥)  | Cap target at 65% of max_stock, floor only   |
| Ramp-Up      | Use RAMP-UP mode regardless of location_type |

## Dead machine rule

< 5 sales in last 7d AND < 20 sales in last 30d = dead machine.
Dead machine: touch only slots where current_stock < floor_qty.
Never top to target on a dead machine.

## Mode is determined per-machine, not per-fleet.

Engine B receives mode as a parameter — it does not derive it internally.
