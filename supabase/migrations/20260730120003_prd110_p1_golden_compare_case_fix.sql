-- PRD-110 STEP 1 fix. Applied via MCP as `prd110_p1_golden_compare_case_fix` 2026-07-30.
-- plpgsql CASE with no matching branch and no ELSE raises case_not_found (20000). The original
-- golden.compare fell through its first CASE for every numeric op, so EVERY numeric assertion
-- errored instead of comparing (observed live: actual 0 vs expect 0 reported as FAILED).
-- Forward-only replacement per Article 12.

CREATE OR REPLACE FUNCTION golden.compare(p_actual text, p_op text, p_expect text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_op = 'is_null'  THEN RETURN p_actual IS NULL;     END IF;
  IF p_op = 'not_null' THEN RETURN p_actual IS NOT NULL; END IF;
  IF p_op = 'contains' THEN
    RETURN p_actual IS NOT NULL AND p_expect IS NOT NULL AND position(p_expect in p_actual) > 0;
  END IF;

  IF p_actual IS NULL OR p_expect IS NULL THEN RETURN false; END IF;

  BEGIN
    IF p_op = 'eq'  THEN RETURN p_actual::numeric =  p_expect::numeric; END IF;
    IF p_op = 'ne'  THEN RETURN p_actual::numeric <> p_expect::numeric; END IF;
    IF p_op = 'gte' THEN RETURN p_actual::numeric >= p_expect::numeric; END IF;
    IF p_op = 'lte' THEN RETURN p_actual::numeric <= p_expect::numeric; END IF;
    IF p_op = 'gt'  THEN RETURN p_actual::numeric >  p_expect::numeric; END IF;
    IF p_op = 'lt'  THEN RETURN p_actual::numeric <  p_expect::numeric; END IF;
    RAISE EXCEPTION 'golden.compare: unknown op %', p_op;
  EXCEPTION WHEN invalid_text_representation THEN
    IF p_op = 'eq' THEN RETURN p_actual =  p_expect; END IF;
    IF p_op = 'ne' THEN RETURN p_actual <> p_expect; END IF;
    RAISE EXCEPTION 'golden.compare: op % requires numeric operands (actual=%, expect=%)',
                    p_op, p_actual, p_expect;
  END;
END $$;
