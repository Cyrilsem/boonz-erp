-- PRD-110 DR-1 (leg 160) — the per-cluster cutover authority registry + its append-only audit.
-- Cody ⚠️ approve-with-revisions; Articles 2, 3, 5, 7, 8, 12, 14 checked.
-- Article 14: neither table materializes a query a view could compute. The registry holds DECISION
-- state (which brain plans a cluster) and the audit is an append-only ledger — the same ground
-- ADR-shadow-plan-tables.md already cleared. No ADR required.
-- ⛔ LAW 4: seeds every cluster at 'v19'. Zero clusters authoritative. This loop never flips it.

-- ── 1. THE REGISTRY ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.engine_cutover_authority_v3 (
  cluster_key           text PRIMARY KEY,
  authoritative_engine  text        NOT NULL DEFAULT 'v19'
                          CHECK (authoritative_engine IN ('v19','v3')),
  flipped_at            timestamptz,
  flipped_by            uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  flip_reason           text,
  flip_evidence         jsonb,
  n_machines_at_flip    integer,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  -- ⭐ THE ANTI-THEATRE CONSTRAINT. A row cannot rest at 'v3' without the timestamp, the human
  --    reason and the evidence snapshot that justified it. There is no quiet flip.
  CONSTRAINT eca_v3_flip_fields_together CHECK (
    (authoritative_engine = 'v19' AND flipped_at IS NULL)
    OR (authoritative_engine = 'v3' AND flipped_at IS NOT NULL
        AND flip_reason IS NOT NULL AND flip_evidence IS NOT NULL)
  )
);

COMMENT ON TABLE public.engine_cutover_authority_v3 IS
 'PRD-110 DR-1. Which refill brain is authoritative for a cluster (machines.venue_group). Ships '
 'flag-off: every cluster v19. Written ONLY by flip_cluster_to_v3_v3 / revert_cluster_to_v19_v3.';
COMMENT ON COLUMN public.engine_cutover_authority_v3.flip_evidence IS
 'Readiness snapshot AT flip time. Denormalized on purpose: an evidence claim that silently '
 're-computes when the gate view changes is not evidence.';

-- ── 2. THE AUDIT LEDGER — refusals are recorded as loudly as applies ─────────
CREATE TABLE IF NOT EXISTS public.engine_cutover_audit_v3 (
  audit_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cluster_key   text        NOT NULL,
  action        text        NOT NULL CHECK (action IN ('flip_to_v3','revert_to_v19')),
  outcome       text        NOT NULL CHECK (outcome IN ('applied','refused')),
  refusal_code  text,
  from_engine   text,
  to_engine     text,
  reason        text        NOT NULL CHECK (length(btrim(reason)) >= 10),
  evidence      jsonb       NOT NULL,
  actor         uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  actor_role    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT eca_audit_refusal_code_iff_refused CHECK (
    (outcome = 'refused' AND refusal_code IS NOT NULL) OR
    (outcome = 'applied' AND refusal_code IS NULL))
);

COMMENT ON TABLE public.engine_cutover_audit_v3 IS
 'PRD-110 DR-1. Append-only record of every cutover DECISION, including refused ones. '
 '"CS tried to flip VOX and the gate said no" is the most interesting row this table will hold.';

-- ── 3. INDEXES (D5 — each serves a named query) ──────────────────────────────
CREATE INDEX IF NOT EXISTS idx_eca_audit_cluster_created
  ON public.engine_cutover_audit_v3 (cluster_key, created_at DESC);
-- Serves: "show this cluster's flip history" — the only read path CS/FE will use.

CREATE INDEX IF NOT EXISTS idx_eca_authority_v3_live
  ON public.engine_cutover_authority_v3 (cluster_key)
  WHERE authoritative_engine = 'v3';
-- Serves cutover_block_reason_v3, asked once per nightly build. EMPTY on apply, by design.

-- ── 4. RLS (Article 2/3/7) — matches the live facing_proposals_v3 idiom ──────
ALTER TABLE public.engine_cutover_authority_v3 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engine_cutover_audit_v3     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS eca_v3_select   ON public.engine_cutover_authority_v3;
DROP POLICY IF EXISTS eca_v3_noupdate ON public.engine_cutover_authority_v3;
DROP POLICY IF EXISTS eca_v3_nodelete ON public.engine_cutover_authority_v3;
CREATE POLICY eca_v3_select   ON public.engine_cutover_authority_v3 FOR SELECT TO authenticated USING (true);
CREATE POLICY eca_v3_noupdate ON public.engine_cutover_authority_v3 FOR UPDATE USING (false);
CREATE POLICY eca_v3_nodelete ON public.engine_cutover_authority_v3 FOR DELETE USING (false);

DROP POLICY IF EXISTS eca_audit_v3_select   ON public.engine_cutover_audit_v3;
DROP POLICY IF EXISTS eca_audit_v3_noupdate ON public.engine_cutover_audit_v3;
DROP POLICY IF EXISTS eca_audit_v3_nodelete ON public.engine_cutover_audit_v3;
CREATE POLICY eca_audit_v3_select   ON public.engine_cutover_audit_v3 FOR SELECT TO authenticated USING (true);
CREATE POLICY eca_audit_v3_noupdate ON public.engine_cutover_audit_v3 FOR UPDATE USING (false);
CREATE POLICY eca_audit_v3_nodelete ON public.engine_cutover_audit_v3 FOR DELETE USING (false);

-- ⛔ S-268: `anon` is named EXPLICITLY and stripped. Two other v3 objects carry a standing
--    anon/PUBLIC EXECUTE leak; this unit does not add a third.
REVOKE ALL ON public.engine_cutover_authority_v3 FROM anon;
REVOKE ALL ON public.engine_cutover_audit_v3     FROM anon;
REVOKE ALL ON public.engine_cutover_authority_v3 FROM PUBLIC;
REVOKE ALL ON public.engine_cutover_audit_v3     FROM PUBLIC;
-- Article 3: the read path survives, the write verbs do not. Writes arrive via DEFINER RPC only.
GRANT SELECT ON public.engine_cutover_authority_v3 TO authenticated;
GRANT SELECT ON public.engine_cutover_audit_v3     TO authenticated;

-- ── 5. ARTICLE 8 — the registry is a canonical-writer target, so it audits ───
DROP TRIGGER IF EXISTS tg_audit_engine_cutover_authority_v3 ON public.engine_cutover_authority_v3;
CREATE TRIGGER tg_audit_engine_cutover_authority_v3
  AFTER INSERT OR UPDATE OR DELETE ON public.engine_cutover_authority_v3
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_write('cluster_key');

-- ── 6. SEED — the 10 LIVE clusters, all v19 (LAW 4) ─────────────────────────
-- ⛔ Seeded by PREDICATE over Active machines, never by a hand-written list. Over ALL machines
--    there are 11 venue groups and the 11th is 'WH' — the warehouse, present only on Inactive
--    rows. A naive seed would have offered CS the warehouse as a flippable cluster.
INSERT INTO public.engine_cutover_authority_v3 (cluster_key, authoritative_engine)
SELECT DISTINCT m.venue_group, 'v19'
  FROM public.machines m
 WHERE m.status = 'Active' AND m.venue_group IS NOT NULL
ON CONFLICT (cluster_key) DO NOTHING;

-- ── 7. POST-IMAGE PROOFS — refuse a partial apply (S-298) ───────────────────
DO $post$
DECLARE
  v_seed int; v_v3 int; v_wh int; v_drift int;
BEGIN
  SELECT count(*) INTO v_seed FROM public.engine_cutover_authority_v3;
  SELECT count(*) INTO v_v3   FROM public.engine_cutover_authority_v3 WHERE authoritative_engine <> 'v19';
  SELECT count(*) INTO v_wh   FROM public.engine_cutover_authority_v3 WHERE cluster_key = 'WH';
  SELECT count(*) INTO v_drift FROM (
    SELECT a.cluster_key, l.venue_group
      FROM public.engine_cutover_authority_v3 a
      FULL JOIN (SELECT DISTINCT venue_group FROM public.machines WHERE status='Active') l
        ON l.venue_group = a.cluster_key
     WHERE a.cluster_key IS NULL OR l.venue_group IS NULL) d;

  IF v_seed <> 10 THEN RAISE EXCEPTION 'DR-1 post-image: expected 10 seeded clusters, got %', v_seed; END IF;
  IF v_v3   <> 0  THEN RAISE EXCEPTION 'DR-1 post-image: LAW 4 VIOLATED — % cluster(s) shipped authoritative for v3', v_v3; END IF;
  IF v_wh   <> 0  THEN RAISE EXCEPTION 'DR-1 post-image: WH was seeded as a cluster'; END IF;
  IF v_drift<> 0  THEN RAISE EXCEPTION 'DR-1 post-image: registry/live cluster drift = %', v_drift; END IF;
  IF has_table_privilege('anon','public.engine_cutover_authority_v3','SELECT') THEN
    RAISE EXCEPTION 'DR-1 post-image: anon still holds SELECT on the registry';
  END IF;
  RAISE NOTICE 'DR-1 tables OK: 10 clusters, all v19, no WH, no drift, anon stripped';
END
$post$;
