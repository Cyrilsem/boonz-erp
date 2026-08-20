# Why v3 "looks" worse than v19 — and why that reading is wrong

19 Aug 2026. Supersedes the accuracy section of CUTOVER-BRIEF-2026-08-17.md.

---

## The headline, reversed

**v3 is not worse than v19. v3 is better, and the instrument that says otherwise is measuring two different things and calling it a comparison.**

Fleet-wide, pooled across every settled series both engines have ever produced:

| Measure                                               | v19    | v3         | Winner         |
| ----------------------------------------------------- | ------ | ---------- | -------------- |
| WMAPE, all settled series                             | 0.7574 | **0.6713** | **v3, by 11%** |
| WMAPE, excluding shelves that sold zero               | 0.7275 | **0.5422** | **v3, by 25%** |
| Head-to-head, same date + same machine + same product | 1.4092 | **0.8746** | **v3, by 38%** |

The head-to-head row is the one that matters. Same day, same shelf, same product, both engines forecasting the same thing. v3 wins in **every cluster**:

| Cluster (2026-08-04, shared shelves) | v19    | v3         |
| ------------------------------------ | ------ | ---------- |
| AMAZON (14 shelves)                  | 1.5686 | **1.1254** |
| INDEPENDENT (9 shelves)              | 5.5960 | **3.1930** |
| OHMYDESK (19 shelves)                | 1.0651 | **0.6071** |

Yet the cutover gate returns `v3_worse_than_v19` for all three. Same data, opposite conclusion.

---

## What actually went wrong — the mechanism

The gate pools **all** settled series per cluster per engine and divides total error by total actual units. It never checks that the two engines are being scored on the same shelves. They are not, and the mismatch is enormous:

| Population             | Series  | Units sold | Avg units/shelf | Shelves that sold **zero** |
| ---------------------- | ------- | ---------- | --------------- | -------------------------- |
| Planned by v19 only    | 155     | 3,140      | **20.26**       | 12 (8%)                    |
| Planned by both        | 42      | —          | ~5.9            | 10                         |
| **Planned by v3 only** | **288** | **672**    | **2.33**        | **126 (44%)**              |

Read the bottom row. v3's score is dominated by 288 shelves that v19 never planned at all — shelves averaging 2.33 units, where **44% sold nothing whatsoever**. v19's score is dominated by 155 fat, fast shelves averaging 20.26 units.

WMAPE is error ÷ actual units. On a shelf that sells zero, any forecast above zero produces pure error against a zero denominator. Those 126 dead shelves contribute **19.2% of v3's total error** — against 3.9% for v19. v3 is not forecasting worse. It is being scored on harder shelves and penalised for the arithmetic.

**And here is the part that stings: those 288 extra shelves are the entire point of v3.** G3 in the PRD is "empty never skipped" — the unconditional rule that an enabled shelf at zero stock always gets a line. G4 is uncensored demand. v3 was built specifically to stop ignoring slow and empty shelves. It did exactly that, and the scoreboard punished it for every single one.

A secondary confound rides on top: v19's evidence pools a fat 26 June day (141 series, 2,935 units) with a thin 4 August one (56 series, 453 units), while v3's is entirely August. Different months, different volumes, one number.

---

## Was this predicted? Yes. On 8 August.

Finding **S-341** in the PRD-110 execution log says it almost exactly:

> "the branch that separates `ready` from `v3_worse_than_v19` is a head-to-head between two different shelf populations scored on two different velocity bases."

It was raised, correctly diagnosed, and then parked with this reasoning:

> "Today this is harmless: every cluster is `is_vacuous` and refuses regardless. **On ~2026-08-11, when the v3 horizons settle, this becomes the number CS reads to authorize the cutover** — and it will look like an apples-to-apples comparison while not being one."

The horizons settled on 11 August. The warning came true on schedule. Nobody re-read it, and the corrected number was never computed — until now.

---

## The retro — six learnings

**1. We judged the new engine by the old engine's scoreboard.**
v3's mandate was to plan shelves v19 skipped. WMAPE's denominator is units sold. Those two facts are in direct conflict, and nobody noticed until the numbers came in. Any metric applied to a system whose _job_ is to expand coverage into low-volume territory will show degradation. The metric needed to change when the mandate changed.

**2. A known defect was parked as "harmless today" without a trigger to un-park it.**
S-341 correctly predicted the date it would stop being harmless. There was no mechanism to bring it back at that date. "Harmless for now" needs an expiry date and an owner, or it is just deferred failure.

**3. Ratio metrics on small denominators are not comparable across populations.**
44% zero-sale shelves makes WMAPE meaningless, not merely noisy. We should be scoring on absolute units of error per shelf, or restricting to shelves with a minimum volume, or both — and reporting coverage separately from accuracy rather than letting one contaminate the other.

**4. Simpson's paradox, in production, on a go/no-go decision.**
v3 wins overall, wins on every like-for-like shelf, and loses in all three per-cluster aggregates. Whenever a decision rule aggregates over groups with different compositions, the aggregate can invert the truth. The gate needed an intersection restriction from day one.

**5. The build had extraordinary discipline about code correctness and almost none about decision correctness.**
78 golden fixtures, byte-level function pinning, a 15-article constitutional review, refusal-logging on the flip RPC. All of that verified _that the switch works_. None of it verified _that the number the switch reads is meaningful_. The gate view has no fixture asserting it compares like with like. Fixture 74, which tests cutover readiness, has been red for a week and was dismissed as calendar drift.

**6. Shadow mode proved the engine runs; it never proved the engine is good.**
Two weeks of nightly shadow runs banked plans nobody read. The comparison that mattered — same shelf, both engines, who was closer — was computable from day one and was computed for the first time today.

---

## What this changes

- **v3 is very likely the better engine.** Two independent methods agree: fleet-wide pooled, and strict like-for-like.
- **The gate is currently wrong and will keep refusing valid clusters.** It needs an intersection restriction before its verdict means anything. That is a change to the cutover decision rule, so it is CS's ruling, not an operator fix.
- **Do not flip today anyway** — not because v3 is bad, but because 42 shared series on one date is too thin to bet the fleet on. The right move is to fix the view, let a week of paired evidence accumulate, then read it again.
- **The six blind clusters still have zero v3 rows.** That problem is unchanged and unaffected by any of this.

## Recommended next steps

1. Rule on the comparison rule: restrict WMAPE to shelves both engines planned on the same date. This is the S-341 decision that was parked.
2. Add a fixture that fails if the gate ever compares non-overlapping populations.
3. Report coverage and accuracy as two numbers, never one. v3's extra 288 shelves are a feature; they should show up as a coverage gain, not an accuracy loss.
4. Re-read the gate after seven days of paired evidence.
5. Get v3 planning in ADDMIND, GRIT, LVLUP, VML, VOX, WPP — still the binding constraint on a full cutover.
