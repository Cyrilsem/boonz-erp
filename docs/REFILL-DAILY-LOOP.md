# The daily refill loop

Six steps. One owner each. The button or the call for each. PRD-127 (2026-09-17/18) added the
first one -- brief, propose, converse, adjust, push -- ahead of what was previously the first
step of the day.

| When                      | Who              | Does                                                                                                                                                                                                                               | With                                                                                                                                                                                                                                                                             |
| ------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Any time before 19:00** | CS               | **Brief**: asks what tomorrow looks like. **Propose**: reads the rendered summary. **Converse**: pushes back in plain language on anything wrong. **Adjust**: re-asks with the correction folded in. Repeats until it reads right. | `propose_refill_plan(plan_date, machine_names, overrides)` -- writes nothing, safe to call as many times as needed. `overrides` carries one-off corrections ("put 6 on AMZ-1046 A02, not 4"); a durable "never recommend this again" goes through `add_refill_directive` instead |
| **19:00**                 | CS               | **Push**: confirms tomorrow's machines and the car split, now already knowing what to expect                                                                                                                                       | FE: pick list, tick, Confirm and Build. Or by message: "confirm and build: AMZ ×5, OMDCW car 2; Mirdif car 1"                                                                                                                                                                    |
| **19:05**                 | CS               | Reads the exception list on the draft, five lines or fewer, and presses Approve                                                                                                                                                    | FE: Draft, Exceptions, Approve. Approve stitches and pushes in one go                                                                                                                                                                                                            |
| **06:00**                 | Simran / Anthony | Pack from the pack screen. Mark All Packed when done                                                                                                                                                                               | FE: Packing                                                                                                                                                                                                                                                                      |
| **On the road**           | Jojo / Anthony   | Field app, line by line. Every return gets a reason. Complete Dispatch per machine                                                                                                                                                 | Field app                                                                                                                                                                                                                                                                        |
| **17:00**                 | Simran           | Warehouse Confirmations: count what came back, split by expiry or flavour where needed, Confirm                                                                                                                                    | FE: Inventory, Start Inventory Control, Confirm                                                                                                                                                                                                                                  |

The propose/converse/adjust loop and the 19:00 Confirm and Build are deliberately two different
calls, not one: `propose_refill_plan` never writes, so CS can iterate on it freely before
`confirm_and_build`/`engine_add_pod` ever touch `pod_refill_plan`. Nothing about 19:00-17:00
below changed.

**What triggers a message to Fable.** An exception the rules do not cover, a machine that
will not complete, a count that does not match. Nothing else. A normal day has no message.

**What CS never has to do again.** Waive a gate. Rewrite a shelf. Move a Remove leg. Run SQL
to close a machine. Restore venue lines.

**Once a week, Sunday.** Read `v_pod_weimi_drift` for the fleet, read the substitution rules
table, add or retire rules. Read `refill_directives` (active blocks) and retire anything that's
stopped being true (a product is back in stock, a machine is no longer paused). Ten minutes.
