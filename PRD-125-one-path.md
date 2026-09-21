# PRD-125 — One path

**Owner:** CS
**Written:** Monday 14 September 2026, 23:30
**Status:** decision document. Replaces the ordering in PRD-124; most of PRD-124's nineteen
items stop existing once this lands.

---

## What is actually wrong

Tuesday's plan was 228 lines. Getting it from "engine built it" to "driver can pack it"
took: 3 approval attempts, 2 gate waivers, 6 shelves rewritten by hand, 41 venue lines
restored by hand, 7 dispatch rows excluded and 6 re-added, 4 lanes added through the
back door, and one raw database update. About two and a half hours and a lot of tokens
for a plan the engine should have produced clean in five minutes.

That is not nineteen bugs. It is one design fault with a lot of scar tissue on it.

**There are two refill systems in the same database and they disagree about everything.**

| Question                        | Engine path (cron, v15)                          | Dictated path (PRD-121 gates) |
| ------------------------------- | ------------------------------------------------ | ----------------------------- |
| How full should a seller be     | To capacity                                      | Never at capacity, top to 10  |
| Where is stock                  | WH_CENTRAL only                                  | WH_CENTRAL only, venue exempt |
| Where is a product on the shelf | WEIMI for fills, `pod_inventory` lot for Removes | WEIMI                         |
| What blocks a plan              | Nothing, it clamps silently                      | G1 to G9, blocking            |
| Who resolves a substitute       | `find_substitutes_for_shelf` v2                  | A human                       |

PRD-121 bolted the second column's gates onto the first column's output. So the engine's
own plan now fails its own gate seventy times, and the only exit is a waiver. A waiver is a
human with SQL. That human has been me, every night, and that is the token bill.

On top of that sit eight guards, each one added after one incident and each one correct on
its own: expiry-to-confirm (PRD-053), internal-move block (PRD-113), lot re-pointing
(PRD-120), the canonical-writer allowlist, the slot guard, the packed-row guard, the
conservation trigger, the manual pick gate. Together they mean a plan cannot move without
someone who knows which RPC to call to get past which guard. The guards were built to stop
bad data. They now stop good plans just as well.

And `pod_inventory` sits in the middle of it as a second source of truth for where things
are, when it was only ever meant to hold expiry.

---

## Six decisions

These are yours. I have written what I think the answer is. Say yes, or change it.

**D1. Fill to capacity is the rule, not the exception.** A lane whose product sells at
3 a day or more fills to WEIMI max. Below that, top to 10 or to max, whichever is lower.
Venue-stocked lanes always fill to max, it is not our stock. **G1 is deleted.** The engine
already does this; the gate was the thing that was wrong.

**D2. WEIMI is the only source for what is on a shelf.** Product identity, stock, capacity,
lane by lane. `pod_inventory` is read for one thing: the expiry date of what is there. It is
never used to decide where a Remove goes, what quantity, or whether a lane is empty. Every
function that reads `pod_inventory` for anything but expiry gets the read replaced. That is
`push_plan_to_dispatch`, `add_dispatch_row`, `return_dispatch_line`, `receive_dispatch_line`,
`v_live_shelf_stock`, and the four triggers that re-point rows. A nightly job aligns
`pod_inventory` lots to WEIMI shelves, keeping every expiry it can and flagging the ones it
cannot.

**D3. Available stock means the warehouse that supplies that machine.** VOX venue products
resolve against WH_MCC and WH_MM. Everything else against WH_CENTRAL. In the engine, in the
substitute finder, in the gate, in the dispatch push. One function, `wh_available_for(machine,
boonz_product)`, and everything calls it.

**D4. The engine substitutes, not a human.** Your rules go into the engine as data, not into
my head:

- Evian: Al Ain Zero if the machine has none, else Aquafina where it is a VOX site
- Hunter bags: Hunter Canister, 9 to a lane, 3 per flavour, capacity override 12
- Freakin Roasted, Dubai Popcorn, Rice & Corn, G&H, Ritz, Zigi: Benlian, Sunbites, Krambals
  in that order, never a product already on another lane of the same machine
- Scarce stock (under 12 fleet-wide) goes to the highest-velocity lane that wants it and
  nowhere else
- Expired on shelf: Remove plus the substitute, on the same line

A `substitution_rules` table, one row per rule, editable from the FE. The engine reads it.
When no rule matches, the lane is left at its current level and appears on the exception
list, it is not silently zeroed.

**D5. The cron builds every night, no manual gate.** 20:00 Dubai, `gate0_require_manual_confirm`
off. The draft goes to the FE with the exception list on top. You approve on the FE in the
morning or override by message. Approval is one button and it is the only gate. The stitch
and the push happen inside it.

**D6. The gate checks the engine's rules, nothing else.** Five checks, all blocking, none
waivable:

- G3 an empty lane has no line and no substitution rule matched
- G5 a product has no Active mapping anywhere
- G7 a Remove with nothing coming in behind it
- G8 stock short at the supplying warehouse, after D3
- G10 a line lands on a lane WEIMI says holds a different product, with no Remove

G2, G4, G9 become columns on the draft, not gate output. If the engine produced it and it
fails one of the five, the engine is wrong and it gets fixed, not waived. The waiver table is
retired.

---

## What this does to the daily loop

| Today                                                 | After                                                            |
| ----------------------------------------------------- | ---------------------------------------------------------------- |
| 19:00 someone confirms picks or the cron does nothing | Cron builds at 20:00 regardless                                  |
| Draft is 30% zeroed on venue lines                    | Draft is complete                                                |
| Gate reports 70 to 80 blocking                        | Gate reports 0 to 5, all real                                    |
| Human waives, rewrites shelves, re-points Removes     | Human reads a five-line exception list                           |
| Human approves via SQL                                | Button                                                           |
| Mark All Dispatched does nothing                      | Button (PRD-124 S2)                                              |
| Returns confirmed one batch per line                  | Split (PRD-123)                                                  |
| Me, every night, three hours                          | Me, when the exception list has something the rules do not cover |

The token cost drops because the work drops. Not because I am used less on the same work.

---

## What falls out of PRD-124

Done by this instead: #44 (D2), #45b (D3), G1 (D1), #45a (D5 makes P1 a sort order not a
gate), G5 (D6), cron 13 (D5), G8d (D3), the waiver reasons. Still needed on their own: #35,
#42, #38, #39, #41, the field Save notice, the migration window, PRD-123.

## What goes in the skill

The refill skill still says "top to about 10, never fill to capacity." That line has cost you
twice this week. It changes to D1. The skill also learns D2 and D4 so that no future session
reads `pod_inventory` for placement or invents a substitute you did not sanction.

---

## Order

1. D2 and D3 first. They are the two that made tonight take three hours. One migration each,
   one function each, everything else calls them.
2. D1 and D6 together, one migration on `validate_refill_plan`.
3. D4, the rules table and the engine hook.
4. D5, the cron.
5. Skill update.

Five days if one Claude Code session a day. The prompt is in `PRD-125-goal-command.md`.
