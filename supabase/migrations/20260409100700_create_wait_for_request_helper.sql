-- CC-00b Step 5d: wait_for_request() — polling helper for pg_net responses
CREATE OR REPLACE FUNCTION public.wait_for_request(
  p_request_id      bigint,
  p_timeout_seconds int DEFAULT 120
)
RETURNS TABLE(
  status_code      int,
  content          text,
  elapsed_seconds  int,
  timed_out        boolean
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_start_time timestamptz := clock_timestamp();
  v_elapsed    int;
  v_row        record;
BEGIN
  LOOP
    SELECT r.status_code, r.content::text
      INTO v_row
    FROM net._http_response r
    WHERE r.id = p_request_id;

    v_elapsed := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time))::int;

    IF v_row.status_code IS NOT NULL THEN
      RETURN QUERY SELECT v_row.status_code, v_row.content, v_elapsed, false;
      RETURN;
    END IF;

    IF v_elapsed >= p_timeout_seconds THEN
      RETURN QUERY SELECT NULL::int, NULL::text, v_elapsed, true;
      RETURN;
    END IF;

    PERFORM pg_sleep(2);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.wait_for_request(bigint, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wait_for_request(bigint, int) TO service_role, authenticated;

COMMENT ON FUNCTION public.wait_for_request(bigint, int) IS
'Polls net._http_response until a request completes or times out. Default timeout 120s. Returns (status_code, content, elapsed_seconds, timed_out).';
