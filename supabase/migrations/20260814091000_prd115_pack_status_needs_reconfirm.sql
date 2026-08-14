-- PRD-115 §2.3 - "already packed" and "1 to resolve" can no longer be true at once.
--
-- INCIDENT: after ops unpacked two rows post-confirm, /field packing rendered
-- BOTH "Machine already packed for 2026-08-14" AND "Finish - 1 to resolve", with
-- the destructive "Override & re-pack" as the only prominent exit. Ops hand-closed
-- the line and re-ran confirm_machine_packed from SQL.
--
-- The two banners were reading two different objects: the amber banner reads
-- pack_confirmed (a row exists in dispatch_pack_confirmation), the Finish button
-- reads the live resolved/total count. Nothing reconciled them, so the pair could
-- disagree forever. This gives the disagreement a NAME.
--
--   pack_state = 'needs_reconfirm'  <=>  a FINAL confirm exists AND the machine is
--                                        no longer ready to close.
--
-- After this migration 'completed' IMPLIES ready_to_pack_close. The combination
-- the incident produced is unrepresentable in the view, which is the acceptance
-- criterion (PRD §4.2).
--
-- WHY c.final GATES IT. "Save & come back" writes a confirmation row with
-- final=false and legitimately leaves lines unresolved; that is 'in_progress' and
-- must stay 'in_progress'. Only a FINAL confirm that has since drifted is
-- 'needs_reconfirm'. Reading needs_reconfirm off pack_confirmed alone would
-- relabel every mid-pack save as a fault.
--
-- ADDITIVE ONLY. 'open' and 'in_progress' are unchanged. 'completed' narrows: it
-- no longer covers the drifted case, because that case is the bug. The two new
-- trailing columns (needs_reconfirm, unresolved_n) let the FE render "M lines to
-- finish" without re-deriving the count client-side (Article 16). No consumer
-- reads pack_state today (grep: zero backend functions, zero FE call sites; the
-- FE reads pack_confirmed and is_pickup_complete), so the narrowing lands on a
-- clean surface.
--
-- ready_to_pack_close is v_dispatch_pack_progress's own definition of "every
-- packable line resolved" - the SAME object confirm_machine_packed gates on. The
-- state and the writer therefore cannot disagree: whatever unblocks Finish is
-- exactly what clears needs_reconfirm.

CREATE OR REPLACE VIEW public.v_machine_pack_status AS
 WITH lines AS (
         SELECT rd.machine_id,
            rd.dispatch_date,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS total_included,
            count(*) FILTER (WHERE COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false) AND (rd.packed OR rd.skipped OR rd.pack_outcome = 'not_filled'::pack_outcome_enum)) AS resolved,
            count(*) FILTER (WHERE rd.packed AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS physical,
            count(*) FILTER (WHERE rd.pack_outcome = 'not_filled'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS not_filled,
            count(*) FILTER (WHERE rd.pack_outcome = 'partial'::pack_outcome_enum AND NOT COALESCE(rd.cancelled, false)) AS partial,
            count(*) FILTER (WHERE rd.skipped AND NOT COALESCE(rd.cancelled, false)) AS skipped,
            count(*) FILTER (WHERE rd.packed AND rd.picked_up AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS picked_up_physical,
            count(*) FILTER (WHERE rd.packed AND rd.dispatched AND COALESCE(rd.include, true) AND NOT COALESCE(rd.cancelled, false)) AS dispatched_physical
           FROM refill_dispatching rd
          GROUP BY rd.machine_id, rd.dispatch_date
        )
 SELECT l.machine_id,
    l.dispatch_date,
    m.official_name AS machine_name,
    l.total_included,
    l.resolved,
    l.physical,
    l.not_filled,
    l.partial,
    l.skipped,
    l.picked_up_physical,
    l.dispatched_physical,
    COALESCE(p.ready_to_pack_close, false) AS is_pack_complete,
    l.picked_up_physical = l.physical AS is_pickup_complete,
    l.dispatched_physical = l.physical AS is_dispatch_complete,
    c.machine_id IS NOT NULL AS pack_confirmed,
    c.confirmed_at,
    c.confirmed_by,
    COALESCE(c.final, true) AS pack_final,
        CASE
            WHEN c.machine_id IS NULL THEN 'open'::text
            -- PRD-115 §2.3: a FINAL confirm that no longer closes is its own state.
            -- Ordered BEFORE 'completed' so the two can never both be true.
            WHEN COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false) THEN 'needs_reconfirm'::text
            WHEN COALESCE(c.final, true) THEN 'completed'::text
            ELSE 'in_progress'::text
        END AS pack_state,
    -- PRD-115 §2.3: the same predicate as the CASE arm above, exposed as a boolean
    -- so the FE can branch without string-matching pack_state.
    (c.machine_id IS NOT NULL AND COALESCE(c.final, true) AND NOT COALESCE(p.ready_to_pack_close, false)) AS needs_reconfirm,
    -- Lines the packer still has to finish. Article 16: derived HERE, from
    -- v_dispatch_pack_progress, never re-counted in the browser.
    GREATEST(COALESCE(p.packable_n, 0) - COALESCE(p.resolved_n, 0), 0) AS unresolved_n
   FROM lines l
     JOIN machines m ON m.machine_id = l.machine_id
     LEFT JOIN dispatch_pack_confirmation c ON c.machine_id = l.machine_id AND c.dispatch_date = l.dispatch_date
     LEFT JOIN v_dispatch_pack_progress p ON p.machine_id = l.machine_id AND p.dispatch_date = l.dispatch_date;

COMMENT ON VIEW public.v_machine_pack_status IS
  'Per machine/date packing state. PRD-115 §2.3: pack_state gained ''needs_reconfirm'' - a FINAL confirm exists but the machine is no longer ready_to_pack_close (a line was unpacked, or a plan edit added one, after the confirm). ''completed'' now IMPLIES ready_to_pack_close, so "already packed" + "N to resolve" is unrepresentable. ''in_progress'' still means a deliberate final=false Save & come back and is untouched. needs_reconfirm/unresolved_n are the FE''s read; the count comes from v_dispatch_pack_progress, the same object confirm_machine_packed gates on, so clearing Finish is exactly what clears the state.';
