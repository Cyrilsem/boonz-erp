# Incident — 2026-04-26 — Non-canonical writes into protected tables

**Severity:** S2 (constitutional violation, no data loss, ongoing in prod)
**Phase / Article:** A.6.0 / Constitution Article 1 (canonical write paths) — investigation triggered by A.5b smoke test
**Status:** Open. Findings catalogued; remediation sequenced (see §6); no immediate user-facing impact.
**Filed by:** assistant (post-A.5b smoke test discovery)
**Owner:** CS (operator-in-chief). Implementation: Stax. Constitutional review: Cody.

---

## 1. TL;DR

Immediately after A.5b shipped (24 canonical writers patched + RLS on `refill_dispatch_plan`), the audit log surfaced one row tagged `via_rpc=false, rpc_name=null` against `machines`. A 24-hour sweep across all 13 protected tables showed the row was not an isolated anomaly — it was the smallest of **four distinct non-canonical write paths** currently in production.

The most material finding: **zero canonical `write_refill_plan` calls in 24 hours** despite 180 direct INSERT/DELETE/UPDATE writes against `refill_plan_output` from a mix of n8n service-role and FE operator_admin sessions. The RPC we patched in A.5b Part 3 is wired correctly but is not on the call path of either of its two real-world writers.

This is a Phase B problem, not a Phase A regression. A.5b is correct as shipped — it makes every **canonical** writer constitutional. What this incident exposes is that the FE/n8n surface has not yet been migrated to call those writers. That migration is exactly what Phase B is for.

---

## 2. Timeline

| When (UTC) | Event |
|---|---|
| 2026-04-26 ~05:00 | A.5b parts 1–4 applied to prod. All 24 patched writers verified `prosecdef=true`, `proconfig` includes `search_path=public`, body contains `PERFORM set_config('app.via_rpc',…)`. |
| 2026-04-26 ~06:05 | A.5b smoke tests scheduled to run. |
| 2026-04-26 06:06:03 | Anomalous `machines` UPDATE writes audit row with `via_rpc=false, rpc_name=null`. Actor: `82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d` (operator_admin, CS himself). |
| 2026-04-26 06:07:44 | A.5b smoke test 1 runs (`toggle_machine_refill`). Two audit rows land with `via_rpc=true, rpc_name='toggle_machine_refill'`. Confirms patch works. |
| 2026-04-26 ~10:00 | Investigation begins. 24h sweep across protected tables. |
| 2026-04-26 ~10:30 | Scope established: 4 violation paths, 186 non-canonical writes total in last 24h. |

---

## 3. Findings (the four paths)

### 3.1 — `machines` repurpose at 06:06:03 — FE direct UPDATE (operator_admin)

**Audit row:** `audit_id=21c0d929-eda3-4eff-a082-f736a6fc6638`
**Row affected:** `machine_id=f48e222a-c66f-45b8-9aa7-b9ab0016ee5e`, `pod_number=BOONZ_82160818`
**Diff (old → new):**
- `official_name`: `LLFP_2006_0000_C0` → `WH2_2006_0000_C0`
- `adyen_store_description`: `LLFP_2006_0000_C0` → `WH2_2006_0000_C0`
- `status`: `Active` → `Inactive`
- (all other fields unchanged)

**Diagnosis:** This is a `repurpose_machine` shape (rename + status flip). The canonical RPC exists, was patched in A.5b, and accepts these exact arguments. The FE either has a "Repurpose" form that issues a direct PostgREST `UPDATE` against `machines`, or this was performed via Studio. Either way, the canonical write path was bypassed.

**Article violated:** 1 (canonical write path) and indirectly 4 (validation — direct UPDATE skips role/input checks).

**Blast radius:** small. One row, legitimate operational change.

### 3.2 — `refill_plan_output` 180 writes — refill-engine skill + FE plan editor

**Window:** rolling 24h ending 2026-04-26 ~10:30 UTC.
**Counts by (role, op):**

| role | op | count | confirmed caller |
|---|---|---:|---|
| service_role | INSERT | 69 | refill-engine skill (§8.2/8.3 in `refill-engine/SKILL.md`) |
| service_role | DELETE | 66 | refill-engine skill (per-run cleanup before insert) |
| operator_admin | UPDATE | 40 | FE plan editor (operator override) |
| service_role | UPDATE | 5 | refill-engine skill (re-run / repair sweeps) |
| **total** | | **180** | |
| **via `write_refill_plan` RPC** | | **0** | — |

**Attribution corrected (Cody review):** The original draft attributed the service_role writes to "n8n daily plan generator." That was wrong. The n8n cron only does **stock refresh every 4h** (per `refill-engine/SKILL.md` §Overview); it does NOT write `refill_plan_output`. A `pg_cron` audit (`SELECT * FROM cron.job`) confirms zero scheduled jobs write to the table. The service_role writes are 100% from the `refill-engine` skill itself, which uses Supabase MCP `execute_sql` to run direct INSERTs (skill §8.2 REFILL rows, §8.3 SWAP pairs, §8.4 dispatch mirror). This makes the skill — not n8n — the canonical-writer-bypass on the service_role side.

**Sample row** (`audit_id=bb7ea371-960f-4e42-a67e-43e423e916d8`):
```
table=refill_plan_output op=INSERT actor=null actor_role=null via_rpc=false
payload.new.comment = "Operator sourcing from Union Coop"
payload.new.machine_name = "OMDCW-1021-0100-W0"
payload.new.shelf_code  = "A07"
payload.new.boonz_product_name = "Krambals - Tomato & Mozzarella"
```
The `comment` field strongly indicates an operator override — confirming the FE plan editor is one of the writers, not just n8n.

**Diagnosis:** Two real-world writers (refill-engine skill, FE plan editor) both bypass `write_refill_plan`. RLS on `refill_plan_output` is permissive (`refill_plan_insert WITH CHECK true`, `refill_plan_update USING true WITH CHECK true`), so authenticated users can INSERT/UPDATE freely; service_role bypasses RLS entirely.

**Article violated:** 1 (canonical write path) on every row.

**Blast radius:** the entire daily refill plan is currently produced and edited outside the constitutional perimeter. Any future audit-driven feature (e.g., "show me which operator changed which plan row") will see only 0 of 180 writes properly tagged. This is the largest open violation in the system today.

### 3.3 — `pod_inventory` × 3 + `warehouse_inventory` × 1 batch remap at 21:29:10 — service_role

**Window:** all four rows landed at exactly `2026-04-25 21:29:10.488206 UTC`.
**Diff:** all four rows had `boonz_product_id` flipped from `19c2983f-…` (Santiveri Cranberries) to `cd5fd194-…` (Santiveri Cran Berry).

**Diagnosis:** This matches the data-correction migration logged in CHANGELOG on 2026-04-26 ("merge Santiveri Cranberries → Cran Berry"). The migration ran with service_role and intentionally wrote without `via_rpc=true`. Not a violation per se — Article 12 forward-only data corrections via `apply_migration` are explicitly permitted — but the audit row shape is indistinguishable from a sloppy ad-hoc UPDATE without context.

**Article violated:** none directly. Documentation gap: data-correction migrations should write a marker row to `write_audit_log` first (e.g., `operation='MIGRATION', payload={migration_name: …}`) so the trail is interpretable later.

**Blast radius:** zero (intentional, logged in CHANGELOG). Filed as a process improvement in §6.

### 3.4 — `machines` updated_at heartbeat at 21:19:26 — service_role

**Audit row:** `audit_id=a1704a36-16ae-4d38-bd06-4637bbd6bcac`
**Row affected:** `machine_id=0a46324c-77f0-4e8f-aa13-2716557c1e27` (`WH3_1047_0000_W0`)
**Diff:** ONLY `updated_at` changed (`2026-04-22T14:42:51` → `2026-04-25T21:19:26`). Every other field byte-identical.

**Diagnosis:** A service-role process is touching `machines` rows just to bump `updated_at`. No business field changes. Suspect: an n8n flow that re-reads a row, computes nothing, and writes it back.

**Article violated:** 1 (writes through service_role direct table access instead of an RPC). Low priority — semantically a no-op.

**Blast radius:** wasted writes; pollutes `updated_at` ordering but does not change observable state.

---

## 4. Why A.5b smoke tests still passed

The patched 24 functions ARE constitutional. The smoke tests confirmed that:
- Calling `toggle_machine_refill(...)` writes `via_rpc=true, rpc_name='toggle_machine_refill'`. ✅
- Calling `refresh_product_scores()` writes the explicit audit row + the matview refresh. ✅

The problem is not that the canonical writers are broken. The problem is that **the canonical writers aren't being called by the actual production write paths** for `refill_plan_output` and one specific `machines` flow. A.5b sealed the door; these findings show the production traffic is going through an unsealed window beside it.

---

## 5. Article-by-article impact

| Article | Status pre-incident | Status post-incident |
|---|---|---|
| 1 — Canonical write paths | "All canonical writers constitutional after A.5b" | True for the 24 functions; **false** for `refill_plan_output` and the `machines` repurpose form, where the canonical writers exist but aren't on the call path. |
| 2 — RLS | A.5b closed the only known gap (`refill_dispatch_plan`) | Still true. RLS on `refill_plan_output` is intentionally permissive but is the ENABLER of §3.2; it must tighten in B.x.4 (after callers migrate). |
| 4 — DEFINER validation / via_rpc | True for the 25 patched writers | True for the 25 patched writers. Direct table writes obviously skip Article 4 entirely; that's the violation. |
| 8 — Universal audit | True (every protected-table mutation writes a `write_audit_log` row) | True — but rows landing with `via_rpc=false` for canonical-shape operations are visible exhaust from §3 violations, not gaps in audit infra. |
| 12 — Forward-only | Holds (data-correction migrations log to CHANGELOG, see §3.3) | Holds. |
| 15 — Governance | Phase A.6 not yet applied | This incident is precisely the kind of drift Article 15's CI lint is supposed to catch in warn mode → block mode. Pulls forward A.6 priority. |

---

## 6. Remediation sequence (Cody-revised, 2026-04-26)

The natural instinct is to tighten RLS on `refill_plan_output` immediately. **That would break the refill-engine skill + the FE plan editor** because they're the actual writers and have nothing else to call. Sequencing matters.

**Pre-flight audit results (Cody-required):**
- **Article 11 (cron writers):** ✅ Clean. Audited `cron.job` — 4 jobs total (`evaluate-lifecycle-nightly`, `nightly-fleet-refresh`, `daily-machine-duplicate-audit`, `refresh-sales-aggregated-10min`). **Zero** write to `refill_plan_output`. The fleet-refresh job calls `refresh_fleet_data(90)` which HTTP-POSTs to the `refresh-stage1` edge function — a separate Article 9 audit (filed as step 11 below), not in B.x scope.
- **Article 10 (skill / n8n writers):** Confirmed via `refill-engine/SKILL.md` §8.2/8.3/8.4 that the **refill-engine skill is the service_role writer**, not n8n. The n8n every-4h cron does stock refresh only. Renamed B.x.1 accordingly.

| # | Step | Owner | Blocks | Notes |
|---:|---|---|---|---|
| 1 | A.6.0 — file this incident report | assistant → CS | nothing | (this document) |
| 2 | Cody review of the sequencing in this §6 | Cody | 3..8 | ✅ Done 2026-04-26 — verdict ⚠️ Approve with revisions; revisions applied in this version. |
| 3 | B.x.3 — refactor FE machines repurpose form to call `repurpose_machine` RPC | Stax | nothing | Smallest scope; proves the canonical-RPC pattern end-to-end. **Cody pre-cleared** — no further review needed before deploy (FE-only call-site rewiring, no DDL, no new RPC). |
| 4 | B.x.1 — refactor refill-engine skill to call `write_refill_plan` RPC | Stax + assistant | 5 | The RPC body in A.5b Part 3 already does DELETE-pending-then-INSERT. Skill-side change: replace direct INSERT/DELETE/UPDATE in §8.2 / §8.3 / §8.4 of `refill-engine/SKILL.md` with a single `SELECT public.write_refill_plan(...)` call per plan. **Cody review required before deploy** (n8n/skill flow change touching protected entity). |
| 5 | B.x.2a — design `update_refill_plan_row(p_id uuid, p_qty int, p_comment text, p_operator_status text)` RPC for the operator-override path | Dara → Cody | 6 | New canonical writer. Article 4 review on input validation + role check + via_rpc tagging. Or — alternative — extend `write_refill_plan` with a partial-update mode rather than a new RPC; Dara to weigh. |
| 6 | B.x.2b — apply 5; refactor FE plan editor to call it | Stax | 7 | Replaces the 40 operator_admin direct UPDATEs. Cody review on FE diff. |
| 7 | **(NEW)** B.x.4-pre — Studio / Postman / direct-PostgREST prod lockdown | Stax + CS | 8 | **Cody-required gate.** Without this, after B.x.4 ships, any `operator_admin` (CS himself in §3.1) can repeat the violation through Studio and the 7-day clean window can't honestly close. Concrete shape: revoke `INSERT/UPDATE/DELETE` on protected tables from `operator_admin` and `authenticated` at the GRANT level, leave only `service_role` and `postgres` writeable. Studio still readable. |
| 8 | B.x.4 — tighten `refill_plan_output` RLS | Stax + Cody | 9 | Drop `refill_plan_insert` and `refill_plan_update` policies; keep `refill_plan_select`; service_role bypasses RLS for the skill until B.x.1 lands. **Tightened gate (Cody-required):** all of (a) zero `via_rpc=false` rows on `refill_plan_output` for 7 consecutive days, **excluding** migration-marker rows from step 10; (b) B.x.1, B.x.2 both deployed and green; (c) A.6 governance lint live at warn-mode (so any new direct writer surfaces at PR time). |
| 9 | A.6 — governance YAML in warn mode (Article 15 CI lint) | assistant + Cody | nothing | Priority pulled forward by this incident. **Lint scope (Cody-required):** flag any new code that issues `INSERT/UPDATE/DELETE` against protected tables outside the 25 canonical writers, AND surface §3.4-class drift (service_role direct UPDATEs to protected tables) on every CI run until removed. Warn-mode first, then promote to block. |
| 10 | Process improvement — data-correction migrations write a `MIGRATION` marker row to `write_audit_log` before the data DML | assistant | nothing | Addresses §3.3 attribution gap. Marker shape: `operation='MIGRATION', table_name='<target>', payload={migration_name: <name>, scope: <row_count_or_filter>}`. |
| 11 | Audit — `refresh-stage1` edge function (called by `refresh_fleet_data`) for protected-entity writes (Article 9) | Stax | nothing | Surfaced during the cron audit. Edge fns must be thin RPC wrappers; if `refresh-stage1` writes to `machines` / `sales_history` / etc. directly, that's a separate canonical-writer-bypass. Out of B.x scope. |
| 12 | Investigation — find the service_role process doing pointless `updated_at` heartbeats on `machines` (§3.4); remove or refactor. **Cross-listed in A.6 governance lint scope (step 9).** | Stax | nothing | Low priority but cheap. Lint will keep surfacing it until fixed. |

A.5c (function-level `SET app.via_rpc`) and A.4.b (audit triggers on Amendment-001 tables) are unchanged and still tracked separately in MIGRATIONS_REGISTRY.

---

## 7. Evidence — exact audit_ids and queries

For repro and future reference:

```sql
-- §3.1 — machines repurpose anomaly
SELECT * FROM public.write_audit_log WHERE audit_id = '21c0d929-eda3-4eff-a082-f736a6fc6638';

-- §3.2 — refill_plan_output 24h sweep
SELECT actor_role, operation, COUNT(*) AS n
FROM public.write_audit_log
WHERE table_name = 'refill_plan_output'
  AND occurred_at >= '2026-04-25 10:30:00'::timestamptz
  AND occurred_at <  '2026-04-26 10:30:00'::timestamptz
GROUP BY 1,2 ORDER BY 3 DESC;

-- §3.3 — 21:29:10 batch remap
SELECT table_name, row_pk, payload->'new'->>'boonz_product_id' AS new_id,
                          payload->'old'->>'boonz_product_id' AS old_id
FROM public.write_audit_log
WHERE occurred_at = '2026-04-25 21:29:10.488206+00'::timestamptz;

-- §3.4 — machines heartbeat
SELECT * FROM public.write_audit_log WHERE audit_id = 'a1704a36-16ae-4d38-bd06-4637bbd6bcac';

-- Snapshot — non-canonical writes by table, last 24h
SELECT table_name, via_rpc, COUNT(*) AS n_writes,
       ARRAY_AGG(DISTINCT COALESCE(rpc_name, '<direct>')) AS rpcs_seen
FROM public.write_audit_log
WHERE occurred_at >= NOW() - INTERVAL '24 hours'
  AND table_name IN ('machines','shelf_configurations','planogram','sim_cards',
                     'slots','slot_lifecycle','pod_inventory','warehouse_inventory',
                     'sales_lines','daily_sales','settlements','refill_plan_output',
                     'refill_dispatch_plan')
GROUP BY 1,2 ORDER BY 1, 2 DESC;
```

---

## 8. Decision points (Cody-resolved)

1. **Sequencing approval.** ✅ Cody approved with revisions; §6 reflects the final order: B.x.3 → B.x.1 → B.x.2 → B.x.4-pre (Studio lockdown) → B.x.4 → A.6.
2. **Studio / Postman lockdown.** ✅ Promoted to mandatory step 7 (B.x.4-pre). Cody verdict: not blocking on B.x.3 (small FE-only scope) but **must land before B.x.4** so the 7-day clean window has no escape hatch.
3. **n8n service_role hygiene (role-scoped JWT).** Parked. Cody verdict: not blocking B.x.3 or B.x.4 for audit purposes — once n8n / skill calls `write_refill_plan`, the RPC body itself sets `app.via_rpc=true` regardless of caller role, so audit tagging is correct. JWT scoping is defense-in-depth (so RLS actually applies to service_role traffic post-B.x.4 instead of being bypassed). Beyond Phase B scope; track as a separate ticket.

---

## 8b. Cody verdict (full)

> **Verdict:** ⚠️ Approve with revisions
>
> **Articles checked:** 1, 3, 10, 11, 12, 13, 15
>
> **Findings:**
> - Article 1 ✅ — overall ordering is sound. B.x.3 first is the right pick.
> - Article 10 ⚠️ — B.x.1 had incomplete scope (n8n flow named, but the actual writer is the refill-engine skill). Add B.x.1.b OR rename B.x.1 to cover the skill. **Resolved:** §6 step 4 now names the skill explicitly as the writer, since skill-read confirmed direct INSERTs. No separate B.x.1.b needed.
> - Article 11 ⚠️ — enumerate cron writers. **Resolved:** zero pg_cron jobs write `refill_plan_output`; pre-flight audit recorded in §6 preamble.
> - Article 12 ✅ — RLS tightening forward-only by construction.
> - Article 13 ⚠️ — B.x.4 gate ambiguous as written. **Resolved:** §6 step 8 now specifies (a) `via_rpc=false` rows specifically, (b) excludes migration-marker rows, (c) requires B.x.1+B.x.2 deployed, (d) requires A.6 lint live at warn-mode.
> - Article 15 ✅ — pulling A.6 priority forward is correct.
>
> Plus three additional points: (a) §3.4 heartbeat must be in the A.6 lint scope, not just the §6 investigation list — applied via cross-listing in step 12; (b) Studio/Postman lockdown promoted to mandatory step 7 (B.x.4-pre); (c) n8n role-scoped JWT parked beyond Phase B.
>
> **Next action:** B.x.3 may proceed without further Cody review. B.x.1, B.x.2a, B.x.4 each return to Cody before deploy.

---

## 9. Cross-references

- A.5b CHANGELOG entry: 2026-04-26 — A.5b applied (the smoke test that surfaced this)
- Constitution Article 1 (canonical write paths)
- Constitution Article 15 (governance — pulls forward A.6 priority)
- MIGRATIONS_REGISTRY.md — A.5c, A.4.b, A.6, B.x rows
- RPC_REGISTRY.md — `write_refill_plan`, `repurpose_machine`, `toggle_machine_refill` (canonical writers that exist but are not all being called)

---

— Filed 2026-04-26 by assistant. Pending Cody review of §6 sequencing.
