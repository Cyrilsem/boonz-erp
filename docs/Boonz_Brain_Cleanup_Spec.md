# Boonz Brain — Repository Cleanup & Organization Spec

**Date:** 2026-06-10 · **Scope:** full skills folder (24 skills) · **Status:** awaiting CS approval before execution

---

## 1. The problem

The folder grew by accretion across three engine generations (Gen 1 monolith → Phase D brain → Phase F conductor + picos). Nothing was ever deleted, only superseded. The result:

1. **Trigger collisions.** Four retired skills (`boonz-master`, `refill-engine`, `refill-brain`, and partially `boonz-legacy`) still carry broad operational trigger language that competes with the live conductor `boonz-master-3`. Any message like "run tomorrow's plan" is contested by up to 5 skills.
2. **Duplicated state.** Engine version tables are copied across master-3 and the picos. Duplication is the mechanism of drift — `boonz-pico-refill-plan` still documents the autonomous-Pearson pass that Refill v2 (2026-06-09) deleted.
3. **Orphaned generation.** `product-opt` / `expiry-opt` are written against Phase D's `orchestrate_refill_plan`. Phase F consumes strategic intents through Pass-1 swaps in `engine_swap_pod`. The docs and the live engine disagree.
4. **No taxonomy.** Boonz ops, Boonz personas, general dev tooling, and ventures tooling (plaid) all live flat in one namespace with no index and no naming convention.
5. **Tribal knowledge not codified.** The SQL conventions that keep every session honest (one query per call, live COUNT(\*), shelf_code padding, etc.) exist only in chat memory, not in the repo.

---

## 2. Inventory & verdicts — all 24 skills

| #   | Skill                         | Gen / Class            | Verdict                                   | Why                                                                                                                                                                     |
| --- | ----------------------------- | ---------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `boonz-master-3`              | Gen 3 conductor        | **KEEP — sole broad-trigger entry point** | Live production conductor. Becomes the only skill allowed generic operational triggers.                                                                                 |
| 2   | `boonz-pico-refill-pm`        | Gen 3 Stage 1          | **KEEP + tighten**                        | Clean. Narrow triggers OK.                                                                                                                                              |
| 3   | `boonz-pico-refill-plan`      | Gen 3 Stage 2          | **KEEP + rewrite description**            | Remove "Pass 2 autonomous Pearson" (deleted in Refill v2). Strip engine version claims — versions live in master-3 only.                                                |
| 4   | `boonz-pico-stitch`           | Gen 3 Stage 3          | **KEEP + strip versions**                 | Clean otherwise.                                                                                                                                                        |
| 5   | `boonz-pico-upstream`         | Gen 3 Layer A          | **KEEP + verify**                         | Verify strategic_machine_tags flow matches Refill v2 Pass-1 behavior.                                                                                                   |
| 6   | `product-opt`                 | Phase D strategic      | **REWRITE**                               | Rewire from `orchestrate_refill_plan` to the Phase F intent-consumption path. Verify live RPCs first.                                                                   |
| 7   | `expiry-opt`                  | Phase D strategic      | **REWRITE**                               | Same as product-opt. Also verify FEFO/linked_intent_id crediting still runs under Phase F reconcile.                                                                    |
| 8   | `boonz-master`                | Gen 1 monolith, ARMED  | **DELETE**                                | `boonz-legacy` already IS its archive. Two copies of the monolith, one with live broad triggers, is the single worst routing hazard in the repo.                        |
| 9   | `boonz-legacy`                | Gen 1 archive, defused | **DELETE** (or 1-week stay)               | Its own retirement criterion — "one full week of clean master-3 operation" — is met as of ~June 11. If CS wants a final safety week, keep until 2026-06-17 then delete. |
| 10  | `refill-engine`               | Gen 1 engine           | **DELETE**                                | Superseded 2026-05-10. Description still claims "Run the Boonz refill brain".                                                                                           |
| 11  | `refill-brain`                | Phase D engine         | **DELETE**                                | master-3 Hard Rule 1 forbids calling Phase D engines. A skill whose only job is to call them has no reason to exist.                                                    |
| 12  | `weekly-procurement`          | Workflow               | **KEEP**                                  | Clean, single-purpose, correctly the only PO-writing path.                                                                                                              |
| 13  | `new-machine-onboarding`      | Workflow               | **KEEP**                                  | Clean.                                                                                                                                                                  |
| 14  | `statement-of-account`        | Workflow               | **KEEP**                                  | Clean.                                                                                                                                                                  |
| 15  | `partner-performance-report`  | Workflow               | **KEEP**                                  | Clean. 1.2M of fonts is fine — assets belong to the skill.                                                                                                              |
| 16  | `context-intelligence`        | Workflow (support)     | **KEEP**                                  | Clean. Called by #15.                                                                                                                                                   |
| 17  | `cody`                        | Persona                | **KEEP**                                  | Governance layer, referenced by master-3 hard rules.                                                                                                                    |
| 18  | `dara`                        | Persona                | **KEEP**                                  |                                                                                                                                                                         |
| 19  | `stax`                        | Persona                | **KEEP**                                  |                                                                                                                                                                         |
| 20  | `plaid`                       | Ventures               | **KEEP — separate domain**                | Not Boonz. Belongs in a ventures namespace, not the Boonz brain.                                                                                                        |
| 21  | `find-skills`                 | Meta                   | **KEEP**                                  |                                                                                                                                                                         |
| 22  | `vercel-cli-with-tokens`      | Dev tooling            | **KEEP**                                  |                                                                                                                                                                         |
| 23  | `vercel-react-best-practices` | Dev tooling            | **KEEP**                                  |                                                                                                                                                                         |
| 24  | `web-design-guidelines`       | Dev tooling            | **KEEP**                                  |                                                                                                                                                                         |
| —   | `boonz-data-conventions`      | **NEW**                | **CREATE**                                | Codifies the SQL/tooling conventions (section 5). Referenced by every Boonz skill.                                                                                      |

**Net result: 24 → 21 skills** (−4 deletions, +1 creation), zero trigger collisions, one entry point.

---

## 3. Target repository structure

Skill loaders require flat folders, so hierarchy is encoded by **naming convention + a registry file**, with optional physical subfolders in the local source-of-truth repo that flatten on sync.

```
boonz-brain/                          (local source of truth)
├── INDEX.md                          ← the registry (see below)
│
├── .claude/
│   └── commands/                     ← the command layer (section 9)
│       ├── goal.md                   ← NEW
│       ├── plaid.md                  ← NEW (wraps the plaid skill)
│       ├── spec.md   fix.md   migrate.md   review.md   (existing)
│
├── docs/
│   ├── goals/                        ← goal specs; /goal <name> executes them
│   │   └── boonz-brain-cleanup.md    ← THIS document, the first goal
│   └── prds/                         ← /plaid writes PRDs here (by area)
│
├── core/
│   ├── boonz-master-3/               ← ONLY broad-trigger skill
│   └── boonz-data-conventions/       ← NEW, shared reference
│
├── refill-pipeline/                  (narrow triggers, explicit stage names)
│   ├── boonz-pico-refill-pm/
│   ├── boonz-pico-refill-plan/
│   ├── boonz-pico-stitch/
│   └── boonz-pico-upstream/
│
├── strategic/
│   ├── product-opt/                  (rewritten for Phase F)
│   └── expiry-opt/                   (rewritten for Phase F)
│
├── workflows/
│   ├── weekly-procurement/
│   ├── new-machine-onboarding/
│   ├── statement-of-account/
│   ├── partner-performance-report/
│   └── context-intelligence/
│
├── personas/
│   ├── cody/
│   ├── dara/
│   └── stax/
│
└── _attic/                           (git history only — NOT synced as skills)
    ├── boonz-master/                 (moved here, then deleted from skill surface)
    ├── boonz-legacy/
    ├── refill-engine/
    └── refill-brain/
```

Non-Boonz skills (`plaid`, `find-skills`, `vercel-*`, `web-design-guidelines`) move to a sibling repo or top-level `general/` folder — they are not part of the Boonz brain and shouldn't be reviewed with it.

### INDEX.md — the registry

One table, kept current as a hard rule, answering for every skill: name, layer, trigger class (BROAD / NARROW / EXPLICIT-ONLY), owner of engine versions (always "master-3"), last-verified date. Any new skill must be added here at creation. This is the file that prevents the next accretion cycle.

---

## 4. Repository rules going forward

1. **One door.** Only `boonz-master-3` carries broad operational triggers. Everything else is NARROW (specific stage/task phrases) or EXPLICIT-ONLY (must be named).
2. **Versions live once.** Engine/RPC version tables exist only in master-3. Picos describe _what_ they do, never _which version_ is live.
3. **Supersede = delete.** When a skill is replaced, the old one moves to `_attic/` (git keeps history) and leaves the skill surface entirely. No defused zombies — `boonz-legacy` proved that "archived but present" still costs review time and trigger ambiguity.
4. **Every Boonz skill cites `boonz-data-conventions`** instead of restating SQL gotchas.
5. **INDEX.md updated in the same commit** as any skill add/change/delete.
6. **Cody reviews** any change to master-3 hard rules or to skills that write to protected entities.

---

## 5. NEW skill — `boonz-data-conventions` (content)

```markdown
---
name: boonz-data-conventions
description: >-
  Shared data-access conventions for ALL Boonz skills working against Supabase
  project eizcexopcuoycuosittm. Reference this before writing any query. Not a
  workflow skill — load when any Boonz skill is active, or when debugging why
  a Boonz query returned wrong/empty results.
---

# Boonz Data Conventions

## Query mechanics

- ONE statement per `execute_sql` call. Multiple statements silently return only the last result.
- `list_tables` row counts are stale planner estimates. ALWAYS verify with live `COUNT(*)`.
- `.limit(10000)` on all Supabase client queries (FE code).
- HTTP 300 = ambiguous FK — disambiguate the relationship explicitly.

## Joins & lookups

- PO lookups: LEFT JOIN `boonz_products`, never INNER (unmatched product IDs drop rows and make POs look closed).
- `slot_lifecycle` joins fan out — always DISTINCT or aggregate. Filter `archived=false AND is_current=true`.
- `product_mapping` is per-machine — dedupe before aggregating against `warehouse_inventory`.
- shelf_code is zero-padded ('B09'); `v_live_shelf_stock.slot_name` is not ('B9').
  Normalize: `LEFT(shelf_code,1) || (SUBSTR(shelf_code,2)::int)::text`.
- Product name resolution: `LEFT JOIN LATERAL v_current_price ON boonz_product_id` → `boonz_product_name`.
- Machine identity: `machines.machine_id` + `machines.official_name`. MCC venue machines do NOT share
  a `machine_mapping` prefix (ACTIVATE-2005 belongs to MCC) — group by mapping then verify membership.

## Time

- All `transaction_date` bucketing: `AT TIME ZONE 'Asia/Dubai'`.
- A Dubai trading day = 20:00 UTC prior day → 20:00 UTC current day.
- Adyen settlement lags T+1/T+2 — absent rows for recent transactions are normal.

## Sales data

- Canonical sales view: `v_sales_transactions`. Filter `delivery_status='Successful'`.
- Brand matching: `pod_product_name ILIKE '%brand%'` directly on the view (don't join boonz_products).
- Adyen join: `merchant_reference LIKE internal_txn_sn_without_suffix || '%'` (strip trailing `_1`).

## Inventory

- Current pod inventory + expiry: `v_pod_inventory_latest`.
- FIFO expiry ordering: `ASC NULLS LAST`.
- Warehouse stock: `warehouse_inventory.warehouse_stock` joined via product_id/boonz_product_id;
  `consumer_stock` is excluded from refill availability.

## Writes (summary — full rules in boonz-master-3 + Cody)

- NEVER raw UPDATE/INSERT/DELETE on pod_refill_plan / refill_plan_output / refill_dispatching — RPCs only.
- n8n inserts dispatch rows with boonz_product_id=null — backfill via product_mapping.
- RLS: EXISTS subquery pattern, never bare auth.uid().
```

---

## 6. Description rewrites (the keepers)

**`boonz-pico-refill-plan`** — new description:

> Boonz Stage 2 — the pod-level refill engine (Refill v2). Runs engine_add_pod (2a fill-to-capacity on selling shelves, WH scarcity the only throttle), engine_swap_pod (2b — Pass 1 consumes strategic_machine_tags + driver wrong_product; swap-in via find_substitutes_for_shelf), engine_finalize_pod (2c consolidate to pod_refill_plan). Engine versions: see boonz-master-3 (single source of truth). Use when CS wants to build the draft, inspect/audit it, re-run a single stage, or run Gate 1. Trigger phrases: run stage 2, replay add/swap/finalize, gate 1, inspect draft. Requires Stage 1 for the plan_date. For general "run refill / today's plan" language, boonz-master-3 conducts.

**`boonz-pico-stitch`** and **`boonz-pico-refill-pm`** — same treatment: strip version claims, add the closing line "For general operational language, boonz-master-3 conducts."

**`product-opt` / `expiry-opt`** — rewritten after live verification (step 2 of the Claude Code prompt) to describe the Phase F path: intent row → strategic_machine_tags (upstream session) → Pass-1 consumption in engine_swap_pod → reconcile crediting. Remove all `orchestrate_refill_plan` references.

---

## 6b. Command layer — `/goal` and `/plaid`

### `/goal` — single purpose: execute this cleanup

`.claude/commands/goal.md` does one thing: points Claude Code at this spec and executes it under hard conditions (echo checklist + wait for green light; read-only verification gate that halts on mismatch; no renames; no touching boonz-master-3; no deletions, attic only; no Supabase writes; out-of-spec = flag, don't do; end with a diff summary and STOP). The file is delivered alongside this spec as `goal.md` — drop it into `.claude/commands/`, save this spec to `docs/goals/boonz-brain-cleanup.md`, run `/goal`.

### `.claude/commands/plaid.md` (NEW)

```markdown
---
description: Generate a PRD via the plaid skill's Plan capability. Writes to docs/prds/<area>/.
---

Invoke the `plaid` skill in Plan mode to produce a PRD.

1. Follow the plaid skill's Plan flow (references/plan.md). HARD RULE from the
   skill: before generating any document from vision.json, run
   `node scripts/validate-vision.js --migrate` and fix errors before proceeding.
2. Write the PRD to docs/prds/<area>/PRD-<slug>.md where <area> matches the repo
   taxonomy (refill-pipeline, strategic, workflows, boonz-brain, …).
3. On completion, suggest /spec to break the PRD into a scoped build prompt.

Argument: $ARGUMENTS = the product/feature/area to plan.
```

---

## 7. Execution order

0. Drop `goal.md` into `.claude/commands/`, save this spec to `docs/goals/boonz-brain-cleanup.md`, run **`/goal`**. Everything below executes inside that run.
1. Verify live RPC surface for strategic intents (grounds the product-opt/expiry-opt rewrite).
2. Create `_attic/`, move the 4 deletions, remove them from the skill surface.
3. Create `boonz-data-conventions`.
4. Apply description rewrites to the 4 picos.
5. Rewrite product-opt + expiry-opt.
6. Create `.claude/commands/goal.md` and `.claude/commands/plaid.md`; create `docs/goals/` and `docs/prds/`.
7. Create INDEX.md.
8. Separate non-Boonz skills into `general/` (or sibling repo).
9. Cody review of the full diff (touches the conductor's documented routing surface).

---

## 8. Execution instructions (the payload `/goal` runs)

When `/goal boonz-brain-cleanup` is invoked, this section is the literal instruction set for the run:

```
You are reorganizing the Boonz Brain skills repository. Work in the local skills
source folder (ask me for the path if not obvious — it contains 24 skill folders
including boonz-master-3, boonz-master, refill-engine, refill-brain).

CONTEXT
- Live conductor: boonz-master-3 (Gen 3 / Phase F, Refill v2 as of 2026-06-09).
- boonz-master, boonz-legacy, refill-engine, refill-brain are superseded generations
  whose trigger descriptions collide with boonz-master-3.
- product-opt and expiry-opt are written against the retired Phase D RPC
  orchestrate_refill_plan; Phase F consumes strategic intents via
  strategic_machine_tags → Pass-1 of engine_swap_pod.
- Supabase project: eizcexopcuoycuosittm.

DO, IN ORDER:

1. VERIFY (read-only, Supabase MCP): confirm which of these RPCs exist and are
   referenced by live cron or engine functions: orchestrate_refill_plan,
   propose_decommission_plan, propose_batch_dissolution_plan, flag_intent_threats,
   engine_swap_pod (inspect via pg_get_functiondef whether it reads
   strategic_machine_tags and/or strategic_intents). Run ONE statement per
   execute_sql call. Report findings before editing anything.

2. RESTRUCTURE the folder:
   - Create subfolders: core/, refill-pipeline/, strategic/, workflows/,
     personas/, _attic/, general/.
   - Move: boonz-master-3 + (new) boonz-data-conventions → core/;
     the four boonz-pico-* → refill-pipeline/; product-opt, expiry-opt →
     strategic/; weekly-procurement, new-machine-onboarding,
     statement-of-account, partner-performance-report, context-intelligence →
     workflows/; cody, dara, stax → personas/; plaid, find-skills,
     vercel-cli-with-tokens, vercel-react-best-practices, web-design-guidelines
     → general/.
   - Move boonz-master, boonz-legacy, refill-engine, refill-brain → _attic/.
     _attic is git-history only: ensure it is excluded from whatever sync
     publishes skills (gitignore-style exclusion or sync config).
   - Do NOT rename any skill folder or the `name:` field in any frontmatter.

3. CREATE core/boonz-data-conventions/SKILL.md with exactly the content in
   section 5 of the spec I will paste below this prompt.

4. EDIT descriptions only (frontmatter `description:` blocks — do not touch
   skill bodies except where stated):
   a. boonz-pico-refill-plan: replace description with the section-6 text.
      In the body, delete any reference to "Pass 2 autonomous Pearson" and any
      engine version numbers; add one line: "Engine versions: see boonz-master-3."
   b. boonz-pico-stitch and boonz-pico-refill-pm: strip engine-version claims
      from description and body; append to description: "For general
      operational language, boonz-master-3 conducts."
   c. product-opt and expiry-opt: rewrite description AND the pipeline-flow
      sections of the body to match the verified Phase F path from step 1
      (intent row → weekly upstream session approves strategic_machine_tags →
      engine_swap_pod Pass-1 consumes them → reconcile credits applied_units).
      Remove every mention of orchestrate_refill_plan. If step 1 shows the
      Phase F path differs from this description, STOP and report instead of
      guessing.

5. CREATE INDEX.md at repo root: a table of every skill with columns
   [skill, folder, layer, trigger_class (BROAD/NARROW/EXPLICIT-ONLY),
   versions_owner, last_verified]. boonz-master-3 is the ONLY row with
   trigger_class=BROAD. Add a rules section copying section 4 of the spec.

6. CREATE the command layer:
   - .claude/commands/plaid.md with exactly the content in section 6b of the
     spec. (goal.md already exists — it launched this run; leave it as-is.)
   - Create empty docs/prds/ directory (with .gitkeep).
   - Do NOT modify the existing spec.md / fix.md / migrate.md / review.md.

7. Output a full diff summary (moved / created / edited / excluded-from-sync)
   and STOP. Do not delete the _attic contents. Do not modify boonz-master-3
   itself. Do not touch anything in the Supabase project — step 1 is
   read-only verification only.

SCOPE: surgical. Only the changes listed above. No refactors beyond what is asked.
```

---

_End of spec. Pending CS approval; Cody review required before the conductor-adjacent description changes ship._
