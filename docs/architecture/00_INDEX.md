# Boonz Backend Architecture — Documentation Hub

This folder is the canonical reference for the Boonz backend reform. Every document here is the source of truth for one slice of the work. If something on the codebase contradicts a document here, the document wins until it is amended via the process in Article 15 of the Constitution.

## Map of this folder

| File | Purpose | Status |
|---|---|---|
| `01_constitution.html` | The 15 articles — write paths, validation, audit, surfaces, schema hygiene, process. The non-negotiables. | Active (v1.0, 2026-04-25) |
| `02_phase_a_plan.html` | The 7 Phase A migrations (A1–A7) that stabilize the perimeter without touching data. | In progress (A1–A4 applied; A4 partial pending Amendment 001) |
| `03_a1_before_after.html` | Side-by-side dashboard of what A1 changed (RLS on `planogram` + `pod_inventory_audit_log`). | Reference |
| `04_a2_before_after.html` | Side-by-side dashboard of what A2 changed (deprecation of `rename_machine_in_place_legacy`). | Reference |
| `05_a3_before_after.html` | Side-by-side dashboard of what A3 created (`write_audit_log` ledger + `audit_log_write()` trigger fn). | Reference |
| `06_amendment_001_appendix_a_reconciliation.md` | Article 15 amendment: reconcile Constitution Appendix A names with the live schema. Filed after A.4 install discovered 6 ghost names. | Draft (pending ratification) |
| `07_amendment_002_article_6_propose_then_confirm.md` | Article 15 amendment: revise Article 6 (warehouse_inventory.status manager-only) to a propose-then-confirm pattern. Adds `warehouse_inventory_status_proposal` to Appendix A. Filed 2026-05-04 alongside Phase 1 of refill-app issues fix. | Draft (pending ratification) |
| `CHANGELOG.md` | Human-readable running log of every architecture-level edit (what / when / why / rollback). | Living |
| `MIGRATIONS_REGISTRY.md` | Index of all Supabase migrations applied as part of this reform, mapped back to the Constitution article they enforce. | Living |
| `RPC_REGISTRY.md` | The 25 canonical writers, 7 read-only helpers, 3 audit/system, 3 trigger-only, plus the deprecation list. The classification that drives Phase A.5. | Living |
| `INCIDENT_2026-04-26_NON_CANONICAL_WRITES.md` | A.6.0 incident report — 4 non-canonical write paths into protected tables, surfaced by A.5b smoke test. Drives B.x.1–B.x.4 sequencing and pulls A.6 priority forward. | Open (pending Cody review of §6 sequencing) |

## How to read these documents

**If you're new to the reform:** Start with `01_constitution.html`. Read all 15 articles. Then skim `02_phase_a_plan.html` to understand the rollout strategy.

**If you're about to make a backend change:** Open `01_constitution.html` Appendix A (protected entities) — if your change touches one, you must follow the canonical-RPC pattern. If it's a new RPC, it must satisfy Articles 1, 4, and 8 before it merges.

**If you're auditing what's been done:** Read `CHANGELOG.md` top-to-bottom and `MIGRATIONS_REGISTRY.md` for the migration trail in Supabase.

**If you're calling Cody (the architecture skill):** Cody loads from these docs. Keep them current — Cody is only as good as the source.

## Phase plan at a glance

| Phase | Scope | What changes | What does NOT change |
|---|---|---|---|
| **A — Perimeter** | DB-only. RLS, audit infra, triggers, RPC tagging, CI lint in warn mode. | Metadata: policies, function bodies, triggers, CI rules. | Zero data rows. Zero FE behavior. |
| **B — Frontend migration** | Per-entity. FE switches from direct table writes to canonical RPCs. CI lint flips to block on direct writes. | FE supabase calls. RPC role-validation lights up. | Data shape. URLs. |
| **C — Surface consolidation** | `/field` ↔ `/app` unification where it makes sense. | UI route structure, shared components. | Backend (already sealed in A+B). |

## Conventions used across these docs

- **Forward-only migrations.** No DROP without a deprecation period. See Constitution Article 12–13.
- **`app.via_rpc` session variable.** Set by every canonical RPC; checked by audit triggers to tag whether a write came through the front door or the side door. See Article 8 + Phase A.3.
- **`SECURITY DEFINER` ≠ god mode.** DEFINER functions still validate role and inputs (Article 4). Without explicit role checks, the route layer is the only guardrail — which is fine in Phase A and tightened in Phase B.
- **"Canonical writer" = an RPC that mutates a protected entity.** It must (1) be the only write path, (2) validate inputs, (3) set `app.via_rpc`, (4) write `write_audit_log`. The 25 in `RPC_REGISTRY.md` are the current list.

## Quick links

- Supabase project: `eizcexopcuoycuosittm` (ap-south-1)
- Production DB tag: `prod` (no preview branch — Pro plan gating; see CHANGELOG 2026-04-25)
- Code repo: this repo, `boonz-erp/`
- The Cody skill (CTO advisor): `/.claude/skills/cody/SKILL.md` (in user-level skills dir, not committed here)

— Last updated: 2026-04-26
