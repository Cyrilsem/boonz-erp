-- PRD-023j (2026-06-17): make the heavy transactions[] array optional in
-- get_vox_commercial_report. Applied to remote via MCP as prd023_j_commercial_optional_transactions.
--
-- Why: the full transactions[] array is 99.9% of the response (1.5 MB for one month,
-- ~5 MB for a year). On a cold Vercel function the first wide-window request assembling
-- that payload exceeded the gateway timeout (504). The cards + waterfall are <1.5 KB.
-- Fix: add p_include_transactions (DEFAULT true => back-compat) and p_txn_limit (DEFAULT
-- NULL => all). The Commercial tab fetches cards with include=false (~1 KB, never 504),
-- then fills the Transaction Detail table with a second non-blocking call. Companion FE:
-- fetchVoxCommercialReport gains includeTransactions; /api/vox/commercial passes it through;
-- loadCommercial does cards-first then transactions-second.
--
-- Signature change => DROP+CREATE (Articles 12/13). Single caller resolves by named args.
-- Read-only; no protected-entity writes. Cody class-c. Transform = guarded in-place rewrite.
DO $mig$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_vox_commercial_report'
    AND pg_get_function_identity_arguments(p.oid) = 'p_pods text[], p_date_from date, p_date_to date';

  IF d IS NULL THEN RAISE NOTICE 'prd023_j: 3-arg not found (already patched), skipping'; RETURN; END IF;
  IF position('p_include_transactions' IN d) > 0 THEN RAISE NOTICE 'already patched'; RETURN; END IF;
  IF position('p_date_to date DEFAULT CURRENT_DATE)' IN d) = 0 THEN RAISE EXCEPTION 'signature drift'; END IF;
  IF position(E'      FROM txn_final\n    )' IN d) = 0 THEN RAISE EXCEPTION 'transactions block drift'; END IF;

  d := replace(d, 'p_date_to date DEFAULT CURRENT_DATE)',
                  'p_date_to date DEFAULT CURRENT_DATE, p_include_transactions boolean DEFAULT true, p_txn_limit integer DEFAULT NULL)');
  d := replace(d, '''transactions'', (',
                  '''transactions'', CASE WHEN p_include_transactions THEN (');
  d := replace(d, E'      FROM txn_final\n    )',
                  E'      FROM (SELECT * FROM txn_final ORDER BY transaction_date DESC LIMIT p_txn_limit) txn_final\n    ) ELSE ''[]''::jsonb END');

  DROP FUNCTION IF EXISTS public.get_vox_commercial_report(text[], date, date);
  EXECUTE d;
END
$mig$;

ALTER FUNCTION public.get_vox_commercial_report(text[], date, date, boolean, integer) SET statement_timeout TO '30s';
GRANT EXECUTE ON FUNCTION public.get_vox_commercial_report(text[], date, date, boolean, integer) TO authenticated, service_role;
