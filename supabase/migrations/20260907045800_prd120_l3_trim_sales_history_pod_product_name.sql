-- PRD-120 L3(c): trim pod_product_name on ingest into sales_history.
--
-- Confirmed before shipping: no writer to sales_history exists anywhere in
-- this repo (grepped supabase/functions/ and n8n/flows/ -- the only hit,
-- evaluate-lifecycle, only READS sales_history via .from(), never inserts).
-- The writer is external (WEIMI/VOX sync outside this codebase). Per the
-- PRD-120 goal's own instruction for exactly this case: document it, ship
-- the DB-side default instead.
--
-- This is defense-in-depth, not a fix for an active bug:
-- v_sales_history_resolved already btrims both sides of the name match at
-- READ time, so an untrimmed name already resolves correctly today. This
-- trigger stops the untrimmed string from ever being stored in the first
-- place, so every other reader of the raw pod_product_name column (several
-- exist -- see the PRD-120 report's list of functions matching sales names
-- outside the resolved view) benefits too, not just the ones that already
-- remember to trim.
--
-- Verified in a rolled-back transaction: inserting '  Sunbites  ' stores as
-- 'Sunbites' (length 8, both leading and trailing whitespace removed).
--
-- Cody: approve, Article 12 (additive trigger, no backfill of existing rows
-- needed since the read-side view already trims defensively).
CREATE OR REPLACE FUNCTION public.trim_sales_history_pod_product_name()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.pod_product_name IS NOT NULL THEN
    NEW.pod_product_name := btrim(NEW.pod_product_name);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_trim_sales_history_pod_product_name
BEFORE INSERT OR UPDATE ON public.sales_history
FOR EACH ROW EXECUTE FUNCTION public.trim_sales_history_pod_product_name();
