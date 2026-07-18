-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260713170328  name: wave1_coexistence_krambals_zigi
-- WAVE-1 (Cody-approved, fast-path config): Krambals & Zigi family self-pair coexistence rule.
INSERT INTO public.coexistence_rules
  (rule_group, a_match_type, a_match_value, b_match_type, b_match_value, scope, rule_type, is_active, note)
SELECT
  'group6b_krambals_zigi_family',
  'family_id', 'c7212554-3dbc-410f-8560-7581221a5b50',
  'family_id', 'c7212554-3dbc-410f-8560-7581221a5b50',
  'machine', 'hard', true,
  'Krambals & Zigi family (c7212554): max 1 variant per machine. Family-id self-pair for the suitability swap engine; supersedes brand-proxy rule group6_krambals_zigi (left active, harmless).'
WHERE NOT EXISTS (
  SELECT 1 FROM public.coexistence_rules
  WHERE rule_group = 'group6b_krambals_zigi_family'
     OR (a_match_type='family_id' AND a_match_value='c7212554-3dbc-410f-8560-7581221a5b50'
         AND b_match_value='c7212554-3dbc-410f-8560-7581221a5b50' AND is_active=true)
);
