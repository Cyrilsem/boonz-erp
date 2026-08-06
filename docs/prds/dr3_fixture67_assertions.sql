-- PRD-110 DR-3 — fixture 67 assertions.
-- Grouping: 1-10 the REVOKE · 11-18 the STRUCTURE · 20-25 the EXECUTED dial (the core) ·
--           26-29 the REPORT · 30-33 the RESIDUE.

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ── THE REVOKE (Article 3) ───────────────────────────────────────────────────
(67, 1, 'DR-3 acceptance: `authenticated` cannot INSERT into pod_inventory. Before DR-3 it held INSERT/UPDATE/DELETE/TRUNCATE on a protected entity — a standing Article 3 violation.',
 'SELECT (value->>''auth_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 2, 'DR-3 acceptance: `authenticated` cannot UPDATE pod_inventory.',
 'SELECT (value->>''auth_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 3, 'DR-3 acceptance: `authenticated` cannot DELETE from pod_inventory.',
 'SELECT (value->>''auth_delete'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 4, 'DR-3 acceptance: `authenticated` cannot TRUNCATE pod_inventory.',
 'SELECT (value->>''auth_truncate'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 5, '⛔ THE READ PATH SURVIVES: `authenticated` still holds SELECT. All five FE call sites (products page, field page x2, field/pod-inventory, AddProductDialog) are .select() only — this assertion is what stops a future over-revoke from silently blanking the field PWA.',
 'SELECT (value->>''auth_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 6, 'DR-3: `anon` holds no INSERT (it never did; the REVOKE is defensive and this pins it).',
 'SELECT (value->>''anon_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 7, 'DR-3: `anon` retains SELECT — the revoke targeted write verbs only.',
 'SELECT (value->>''anon_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 8, '⭐ DELIBERATE, AND ASSERTED SO IT STAYS DELIBERATE: `service_role` KEEPS its write privileges. It is the n8n / break-glass path, this build cannot read the n8n flows to prove none of them writes, and revoking a privilege whose consumers are unverifiable is how a nightly job dies silently at 02:00. The write-guard covers service_role instead. A future silent revoke fails here and has to be argued for.',
 'SELECT (value->>''svc_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 9, 'Article 2: RLS stays enabled on pod_inventory. DR-3 neither disables nor weakens it.',
 'SELECT (value->>''rls_on'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 10, 'NON-VACUITY: pod_inventory holds rows, so the executed probes at seq 20-25 act on something real rather than on an empty table.',
 'SELECT (value->>''pod_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),

-- ── THE STRUCTURE ────────────────────────────────────────────────────────────
(67, 11, '⛔ NON-VACUITY FOR THE WHOLE REVOKE: all 14 pod_inventory writer functions are SECURITY DEFINER owned by postgres. That is the ONLY reason revoking from `authenticated` does not break production — a definer runs as its owner and never consults the caller''s table grant. If this ever reads < 14, a writer has been converted to INVOKER and the revoke has silently become an outage.',
 'SELECT (value->>''writers_definer_postgres'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '14', true, 'P1'),
(67, 12, 'The pre-existing INSERT guard trg_block_direct_pod_inventory_insert still exists. DR-3 adds to it, never replaces it.',
 'SELECT (value->>''insert_guard_trg'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),
(67, 13, '⛔ THE INSERT GUARD IS BYTE-UNTOUCHED. Folding INSERT into DR-3''s dial would have made it BYPASSABLE at ''off'' — a downgrade dressed as a unification. This md5 is what forbids that refactor.',
 'SELECT (value->>''insert_guard_md5'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'a9274436e61d0316d35010fa738c2b97', true, 'P1'),
(67, 14, 'The new guard covers the two verbs nothing guarded before: BEFORE UPDATE OR DELETE.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'BEFORE UPDATE OR DELETE', true, 'P1'),
(67, 15, 'The new guard is FOR EACH ROW — a statement-level trigger would miss which rows were touched and could not gate per-write.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'FOR EACH ROW', true, 'P1'),
(67, 16, 'The new trigger is bound to guard_pod_inventory_write, not to some other function that happens to exist.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'guard_pod_inventory_write', true, 'P1'),
(67, 17, '⛔ LAW 4: DR-3 SHIPS FLAG-OFF. The dial reads ''off'' in production. ⛔ Do NOT re-baseline this to arm the guard — arming it is a CS decision that needs the seq 26-29 report to have run for two weeks first (BUILD SPEC P1.4 line 68).',
 'SELECT (value->>''dial_live'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'off', true, 'P1'),
(67, 18, 'The CHECK constrains the dial to exactly the four defined levels. This is what stops a ''blocked'' typo from silently disarming the guard (the DR-4 seq-6 lesson).',
 'SELECT (value->>''dial_check'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', '''off''::text, ''warn''::text, ''block''::text, ''frozen''::text', true, 'P1'),

-- ── THE EXECUTED DIAL — the core (D-47 / S-173: a guard passed by inspection is not passed) ──
(67, 20, '⭐ EXECUTED at ''off'': a non-RPC UPDATE still SUCCEEDS. If this ever reads a SQLSTATE, DR-3 shipped ARMED and every direct pod_inventory write in production is being refused.',
 'SELECT (value->>''err_off'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 21, '⭐ EXECUTED at ''warn'': a non-RPC UPDATE still SUCCEEDS. The WARNING is the entire difference from ''block'', which is what makes ''warn'' a safe burn-in step.',
 'SELECT (value->>''err_warn'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 22, '⭐⭐ EXECUTED at ''block'': a non-RPC UPDATE is REFUSED with 42501 (insufficient_privilege). ⛔ THIS IS THE GAP DR-3 EXISTS TO CLOSE — before this migration, UPDATE on pod_inventory was guarded by NOTHING, while INSERT had been guarded since PRD-012. ⛔ Do not soften to not_null: the SQLSTATE is the claim, and a 23503 here would mean the guard did not fire and an FK caught the write instead.',
 'SELECT (value->>''err_block'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),
(67, 23, '⭐⭐ EXECUTED at ''block'' WITH app.via_rpc=''true'': the UPDATE SUCCEEDS. This is the assertion that proves DR-3 GUARDED production rather than BROKE it — the 14 canonical writers all set this GUC.',
 'SELECT (value->>''err_block_rpc'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 24, '⭐ EXECUTED at ''block'', DELETE verb: REFUSED with 42501. UPDATE and DELETE were BOTH unguarded, and proving one is not proving the other.',
 'SELECT (value->>''err_block_del'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),
(67, 25, '⭐⭐ EXECUTED at ''frozen'' WITH app.via_rpc=''true'': REFUSED anyway with 42501. ⛔ THIS IS THE ONLY THING THAT DISTINGUISHES ''frozen'' FROM ''block'', and it is precisely what "pod_inventory becomes read-only historical" means in BUILD SPEC P1.4. If this ever reads NONE, ''frozen'' has silently degraded into a second ''block'' and the freeze does not exist.',
 'SELECT (value->>''err_frozen_rpc'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),

-- ── THE REPORT ───────────────────────────────────────────────────────────────
(67, 26, 'The daily-delta report covers a 30-day rolling window with no gaps (days with no writes appear as zero rows, never as absent rows — an absent day reads as "quiet" when it may mean "the report broke").',
 'SELECT (value->>''view_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '30', true, 'P1'),
(67, 27, 'NON-VACUITY: the report actually sees pod_inventory writes. A report that reads zero everywhere would make the freeze look safe for the worst possible reason.',
 'SELECT (value->>''view_max_writes'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),
(67, 28, '⭐ THE HONEST HEADLINE: at least one day reads freeze_readiness=''not_ready''. inventory_events holds ~65 rows against ~150-215 pod_inventory writes PER DAY — the replacement is NOT yet carrying the load, and the report is built to keep saying so. ⚠️ When this legitimately goes to 0, that is the signal the freeze is worth discussing, not a fixture failure — re-baseline it THEN, with the readiness evidence, never before.',
 'SELECT (value->>''view_notready_days'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),
(67, 29, 'The report surfaces the live dial, so a reader of the board can never mistake which enforcement level produced the numbers.',
 'SELECT (value->>''view_dial_passthru'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'off', true, 'P1'),

-- ── THE RESIDUE ──────────────────────────────────────────────────────────────
(67, 30, 'RESIDUE: the dial is back at ''off'' after the probe. The probe drove it through warn/block/frozen; if any of that survived, this fixture would have armed a production guard as a side effect.',
 'SELECT (value->>''dial_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'off', true, 'P1'),
(67, 31, 'RESIDUE: pod_inventory row count is unchanged. The probe issued a real DELETE at seq 24 — this proves it was discarded rather than committed.',
 'SELECT (((SELECT value->>''pod_rows_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after'') = (SELECT value->>''pod_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''))::text)', 'eq', 'true', true, 'P1'),
(67, 32, 'RESIDUE (S-197): app.via_rpc does not leak out of the probe. A leaked ''true'' would silently disarm the guard for every later statement in the session — the exact GUC-leak class S-197 records.',
 'SELECT (value->>''via_rpc_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'UNSET', true, 'P1'),
(67, 33, 'NON-VACUITY FOR seq 25: the probe really did reach the ''frozen'' level. Without this, a probe that aborted early would leave err_frozen_rpc at its initial value and seq 25 could never distinguish "refused" from "never attempted".',
 'SELECT (value->>''dial_in_probe'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'frozen', true, 'P1');
