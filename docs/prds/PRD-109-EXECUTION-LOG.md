# PRD-109 — Execution Log (Pre-Flight Refill Gate)

**Codename:** preflight · **Started:** 2026-07-29 · **Project:** eizcexopcuoycuosittm (PostgreSQL 17.6)
**Status:** PARTIAL — `preflight_refill_plan` SHIPPED and verified in prod. The stitch gate **IS wired,
in WARN MODE** (`refill_policy_params.preflight_enforcement = 'warn'`) — it reports and never refuses;
the flip to `'block'` is a manual CS decision after burn-in (see Phase 4). pgTAP, the frozen fixture,
the Article-15 note and the PRD-107 FE deploy are not done. Reasons below; nothing is silently skipped.

> Sections below marked "Phase 0-3" were written before the gate was wired; **Phase 4 supersedes the
> "NOT DONE" list that follows Phase 3.**

---

## Phase 0 — Survey

### 0.1 Extra Gum reproduced, and it is subtler than the PRD states

Pod `Extra Gum` (5b7075fe) maps to **two** boonz products:

| Variant                    | Mapping                                                                    | Pickable |
| -------------------------- | -------------------------------------------------------------------------- | -------- |
| Extra Gum - **Peppermint** | Active, **machine-scoped** on ~40 machines                                 | **0**    |
| Extra Gum - **Spearmint**  | Active **global-default** (+ an Inactive machine-scoped row on LVLUP-1018) | **19**   |

The resolver orders `(machine_id = p_machine_id) DESC, is_global_default DESC`, so the machine-scoped
Peppermint row always wins and the 19 Spearmint units are never consulted. Machine scope picked the
SKU and hid the sibling. Exactly the shadow the PRD describes.

### 0.2 🚨 The symptom is an ABSENCE, so INV-01 as specced could never catch it

**There are no Extra Gum rows in `refill_plan_output` at all** for 2026-07-25..30. The stitch dropped
the line as `total_wh_stockout`. INV-01 as literally written — _"every qty>0 line has pickable ≥ qty"_ —
iterates over planned lines, and there is no planned line to iterate over.

Resolved by splitting the responsibility, keeping both invariant ids as specced:

- **INV-01** guards planned lines (coverage): name-level pickable < qty → violation.
- **INV-10** is the **absence detector**: a live, enabled, non-broken shelf at 0 stock on a machine that
  _has_ a plan, with **no** REFILL/ADD NEW line for that pod. It reports name-level units so a genuine
  stockout is distinguishable from a shadowed one, and its `fix_path` branches on exactly that.

This is faithful to the PRD, which already assigns INV-10 the _"gum shelf stays empty"_ class.

### 0.3 Name-family rule (INV-01/02), validated

Fuzzy name matching is unsafe here — `Hunter` would swallow `Hunter Ridge` (two distinct live pods).
The family is therefore: **all boonz ids with an Active `product_mapping` from the pod at ANY scope**,
UNION **all boonz sharing a non-NULL `product_family_id`** with those. Mapping-based is precise;
`product_family_id` covers siblings with no mapping row (50 of 356 boonz products have a NULL family,
so family alone is insufficient).

Validated on the incident: **2 variants, 19 units.** Exactly the PRD's expected finding.

Every WH aggregation dedupes by `wh_inventory_id` **before** any mapping join (fan-out trap: mapping
inflates stock 10-40x; Red Bull once read 1599 against a real 39).

---

## Phase 1 — Cody review (BEFORE apply)

**Verdict:** ✅ Approve · **Articles checked:** 4, 12, 13, 14, 16

- **Art. 16 ✅** reads canonical objects only: `v_wh_pickable`, `v_live_shelf_stock`,
  `v_dispatch_pack_progress` (PRD-107), never base tables for a registered metric.
- **(c) 1 ✅** `SECURITY INVOKER` is sufficient and is what shipped. No DEFINER.
- **(c) 2 ✅** zero write statements — read-only is a permanent property.
- **Art. 13/14 ✅** new name, no overload (42725 trap), no `_v2` object.

---

## Phase 2 — Applied

| Migration                                                | Result                                                                                                                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prd109_preflight_refill_plan`                           | ✅ `preflight_refill_plan(date)` → `(verdict, violations, warnings, checked_at, invariant_versions)`. STABLE, SECURITY INVOKER, all 12 invariants |
| INV-06 conservation fix (assertion-guarded substitution) | ✅ removed 3 false positives                                                                                                                      |

**INV-06 false positive, caught before wiring the gate.** `pod_refill_plan` carries **both** a `REMOVE`
and an `M2W` parent for the same (shelf, pod), while the plan records children only as `REMOVE`. The
action-matched join left every M2W parent with "children sum 0". Manual reconciliation proved all
parents balance exactly (Loacker 12=12, Tamreem 9=9, Ice Tea 11=11). Fixed by matching children across
both parent actions. **Had this shipped into a blocking gate it would have refused valid plans** — which
is precisely why the gate was not wired before the invariants were shown clean.

---

## Phase 3 — Replay results (live prod)

`preflight_refill_plan('2026-07-29')` → **FAIL**, 20 violations, 89 warnings, **310 ms**.

| Invariant  | Fires on                                                                                                                                       | Verdict vs acceptance                               |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| **INV-03** | MC-2004 A15 **Barebells**, MC-2004 A06 **Coca Cola Zero**, HUAWEI-2003 A12 **Coca Cola Zero**, MC-2004 A11 Freakin, B02 Sunbites, B03 Red Bull | ✅ **exactly the named duplicate-facing incidents** |
| **INV-04** | MC-2004 **A15 Dubai Popcorn** — "every ADD NEW on this shelf resolved not_filled or skipped"                                                   | ✅ **exactly the named orphan**                     |
| **INV-01** | JET-1016 Ritz Cracker (12u < qty), OMDCW A05 Keen Health (0u across 3 variants)                                                                | ✅ fires, but see the gap below                     |
| INV-12     | OMDCW A05 Keen Health — no units in serving warehouses                                                                                         | ✅                                                  |
| INV-10     | fires on 2026-07-27 (a date with a shelf genuinely at 0)                                                                                       | ✅ absence detector proven                          |
| INV-06     | 0 after the fix                                                                                                                                | ✅                                                  |

**Runtime 310 ms against a 10 s budget.** ✅

### ⚠️ The 07-29 fixture cannot be reproduced from live data

`preflight_refill_plan(p_plan_date)` reads **current** warehouse and shelf state against a
**historical** plan. The single live Extra Gum shelf (VML-1004 A1) now reads **7 of 8** — it has since
been refilled — so INV-10's absence detector correctly does not fire, and there is still no Extra Gum
plan line for INV-01 to check. **The acceptance criterion "INV-01 cites Extra Gum, 19u found" is
therefore NOT met, and cannot be met without frozen snapshots** (the `golden_v2` pattern: freeze
`v_wh_pickable` / `v_live_shelf_stock` / plan as of the incident date and run preflight against them).

What _is_ proven: the name-family rule returns **exactly 19 units across 2 variants** for Extra Gum
(§0.3), so the detection logic is correct — only the historical replay harness is missing.

---

## NOT DONE (explicit)

1. **The stitch gate is not wired.** `stitch_pod_to_boonz(p_dry_run=false)` does not yet call preflight,
   and `p_force` / `p_force_reason` do not exist. Deliberate: it is a 49 KB `SECURITY DEFINER` canonical
   writer with **4 DB callers** (`restitch_after_edits`, `reset_and_restitch`, `commit_refill_plan_atomic`,
   `reopen_stitched_rows`) plus 1 FE call site, and adding parameters forces a `DROP` + `CREATE` of the
   whole body. Wiring it before the invariants are false-positive-clean would have blocked valid plans —
   INV-06 alone would have done so. **INV-11 currently emits 89 warnings on one plan date and needs
   tuning before it is trusted near a gate** (warnings do not block, but the noise hides signal).
   Signature plan when resumed: `DROP` the 2-arg and `CREATE` the 4-arg with defaults — do NOT add
   alongside, or all five existing 2-arg call sites become ambiguous (42725).
2. **pgTAP suite not written** — 24+ fixtures (one violating + one passing per invariant), verdict
   aggregation, force-path audit row. Verification here was live replay, not pgTAP.
3. **Frozen 07-29 fixture not built** — see above.
4. **FE Commit surface and 8pm advisory wiring not done.**
5. **Growth rule not yet recorded in the Constitution docs** as an Article-15 process note. It is
   captured in the function comment and in `invariant_versions` (`set_version: v1`).

## Carry-forward

- Tune INV-11 (89 warnings) and re-check INV-02's warning volume before gating.
- INV-07 and INV-11 currently share a predicate shape ("pod not on any WEIMI slot"); differentiate them
  or merge, so the same fact is not reported twice under two ids.
- Violations are per plan LINE, so a 4-variant Barebells swap yields 4 INV-03 rows. Consider deduping
  by (machine, shelf, pod) for the advisory surface.

---

## Phase 4 — Gate wired (WARN MODE) + invariant tuning · 2026-07-29

### 4.0 ⚠️ Correction: the gate was briefly applied as BLOCKING

`prd109_stitch_preflight_gate` shipped the gate as unconditionally blocking. The CS scope
correction (warn mode) arrived immediately after that apply. Because **every historical plan date
currently returns FAIL**, a blocking gate would have refused real commits. Corrected within minutes by
`prd109_preflight_enforcement_warn_mode`, which makes enforcement param-driven and defaults it to
`warn`. **Live mode verified as `warn`.** No commit was attempted in the interval.

### 4.1 Enforcement is param-driven and ships as `warn`

`refill_policy_params.preflight_enforcement` TEXT NOT NULL DEFAULT `'warn'`, CHECK in (`warn`,`block`).

- **`warn`** — stitch calls preflight, attaches the full verdict + violations + warnings to its return
  payload, and **never refuses**. This is what shipped.
- **`block`** — refuses on FAIL unless `p_force=true` with `p_force_reason` >= 10 chars, writing an
  audited row to `preflight_override_log`.

**The flip to `block` is NOT made in this session.** It is a manual CS decision after ~7 quiet plan
dates of burn-in. The acceptance criterion _"stitch(false) hard-refuses on FAIL"_ is therefore
**DEFERRED to that flip by design, not failed** - the code path exists and is proven (below).

### 4.2 Signature change and call sites

`DROP` the 2-arg, `CREATE` only the 4-arg `(p_plan_date date, p_dry_run boolean, p_force boolean
DEFAULT false, p_force_reason text DEFAULT NULL)`. **Verified `pg_proc` = 1 row** - with exactly one
function present, the four DB callers (`restitch_after_edits`, `reset_and_restitch`,
`commit_refill_plan_atomic`, `reopen_stitched_rows`) and the FE call site all pass 2 arguments and bind
unambiguously to the defaults. Adding the 4-arg alongside the 2-arg would have made every one of them
`42725 function is not unique`.

FE (`RefillPlanningTab.tsx`) now captures the stitch response: it throws on
`status='preflight_failed'` (the future `block` path) and logs a console warning when the verdict is
FAIL under `warn`. `npx tsc --noEmit` clean.

### 4.3 Gate behaviour proven (single transaction, rolled back)

Synthetic `ADD NEW` for a pod already on VOXMM-1013 -> guaranteed INV-03 violation.

| Test                                    | Result                                                                     |
| --------------------------------------- | -------------------------------------------------------------------------- |
| preflight verdict                       | FAIL, 1 violation ✅                                                       |
| **`warn` + commit**                     | proceeded past the gate, **never refused** ✅                              |
| **`block` + commit**                    | `status='preflight_failed'`, violation_count 1 ✅                          |
| **`block` + `p_force` + valid reason**  | proceeded past the gate ✅                                                 |
| **`block` + `p_force` + 5-char reason** | rejected: _"p_force requires p_force_reason of at least 10 characters"_ ✅ |
| `preflight_override_log` insert + CHECK | insert succeeds; short reason blocked by CHECK ✅                          |

**Note on the audit row.** In the probe the override row read 0 because the PL/pgSQL exception block
rolled it back together with the stitch body's own `no approved rows` precondition error. That is the
correct semantic and not a defect: the override row is written in the **same transaction** as the
commit, so if the commit does not happen, no override is recorded. The table and its CHECK were
verified independently.

### 4.4 Invariant tuning (the enforcement-flip blocker)

**INV-02** was firing 80 warnings on one date because it tested _"family total > scoped SKU stock"_,
which is true of almost any multi-flavour pod. Tightened to the PRD's actual wording - a **global-only
sibling variant WITH stock that the machine scope excludes** (the Extra Gum shape): the machine must
have an Active machine-scoped mapping, and a sibling holding stock must have no machine-scoped Active
mapping for that machine.

**INV-07 / INV-11 differentiated.** Both shared the predicate _"pod not on any WEIMI slot"_, making
INV-11 a noisier duplicate of the same fact. INV-07 keeps REFILL slot-guard parity (violation).
INV-11 now owns genuine **`pod_inventory`-vs-WEIMI drift**: a REMOVE line whose pod WEIMI no longer
shows, while `pod_inventory` still carries Active stock for it (warning).

| Date       | warnings before | warnings after | INV-11 before | INV-11 after |
| ---------- | --------------- | -------------- | ------------- | ------------ |
| 2026-07-29 | 89              | **26**         | 9             | **1**        |
| 2026-07-28 | -               | 25             | -             | 1            |

Correction to Phase 3 of this log: the 89 warnings were **INV-02 (80) + INV-11 (9)**, not INV-11 alone
as first written.

### 4.5 INV-06 confirmed as TRUE positives

The two 07-28 INV-06 hits are real conservation breaks, verified by an independent query:
USH-1008 A14 Be-kind Cluster parent 8 vs children 7 (1 unit leaked); ADDMIND-1007 A13 Hunter parent 3
vs children 4 (1 over-emitted). Same-shelf and any-shelf sums agree, so not a join artifact. This is
the `bug_conservation_counts_superseded_remove` class the PRD names.

### 4.6 Clean-plan safety proof

A synthetic clean plan (VOXMM-1013, REFILL 10 of Chocolate Bar, machine has zero empty shelves,
8205 serving-WH units) returns **PASS_WITH_WARNINGS with 0 violations**. The gate would not block a
good plan - the prerequisite for ever flipping to `block`.

---

## STILL NOT DONE

1. **Frozen 07-29 fixture harness** (golden_v2-style snapshots of `v_wh_pickable` /
   `v_live_shelf_stock` / plan). Live replay is proven and stable, but preflight reads CURRENT stock
   against a HISTORICAL plan, so the Extra Gum 19u condition has already drifted (that shelf now reads
   7/8). Without frozen snapshots the incident cannot be pinned as a permanent regression test.
2. **pgTAP suite** - 24+ fixtures, one violating + one passing per invariant, verdict aggregation, and
   the force-path audit row under `block`. The gate behaviours in 4.3 were proven by rolled-back SQL
   probes, which is evidence but not a suite.
3. **Article-15 growth-rule note** in the Constitution docs. The rule is captured in the
   `preflight_refill_plan` comment and in `invariant_versions` (`set_version: v1`) but not yet in
   `01_constitution.html`.
4. **PRD-107 FE bundle not deployed to Vercel.** The working tree carries a large number of unrelated
   modified files; a clean PRD-107-only commit needs deliberate file selection, and I would rather do
   that as a focused first action than at the tail of a long session. Backend has been live since
   morning, so nothing is half-deployed - the FE is simply still pending.

## Burn-in checklist before flipping `preflight_enforcement` to `block`

- [ ] ~7 consecutive plan dates where preflight returns PASS or PASS_WITH_WARNINGS on the real plan.
- [ ] INV-02's remaining ~25 warnings/date triaged: either real mapping shadows to fix, or tighten again.
- [ ] INV-01 / INV-12 confirmed to fire only on genuine shortfalls (both currently fire on every
      historical date; needs a live pre-commit sample to judge).
- [ ] pgTAP green.
