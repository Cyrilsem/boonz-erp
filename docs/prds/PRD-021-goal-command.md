# /goal — PRD-021 (paste into Claude Code, repo root)

```
/goal Execute docs/prds/PRD-021-ritz-decommission-lift.md on Supabase eizcexopcuoycuosittm. Goal: close the Ritz Cracker decommission intent so the swap engine stops phasing Ritz out. CS lifted Ritz decommission 2026-06-10 (selling well at Amazon); Loacker Quadratini decommission STANDS.

TARGET: strategic_intent ba1ef467-0252-4541-90b5-0e9342754569 (intent_type decommission, scope_boonz_product_id 2e20605a-e4fe-4407-a4ce-60b194e69d34 = Ritz Cracker - Regular, status queued). Close via canonical writer abandon_intent(p_intent_id, p_reason).

BLOCKER: abandon_intent raises 'requires authenticated operator role' under service-role (auth.uid() IS NULL). FIX (Cody-gated): add the standard service-role bypass to abandon_intent's role guard — only enforce the operator-role check when auth.uid() IS NOT NULL, so service-role passes. Pattern, verbatim body otherwise:
  IF auth.uid() IS NOT NULL AND NOT <existing operator-role check> THEN RAISE EXCEPTION 'abandon_intent: requires authenticated operator role'; END IF;
Same one-line bypass already applied this session to update_dispatch_comment / adjust_pod_inventory / set_dispatch_include. Migration name prd021_abandon_intent_service_role_bypass; add the local migration file. Route through Cody BEFORE apply (Hard Rule 6).

EXECUTE (after Cody approves):
1. Apply the bypass migration.
2. SELECT abandon_intent('ba1ef467-0252-4541-90b5-0e9342754569','CS 2026-06-10: lifting Ritz Cracker decommission — selling well at Amazon, resuming as active SKU. Supersedes the 2026-05-10 permanent-decommission rule for Ritz only; Loacker Quadratini decommission stands.');
3. VERIFY: strategic_intents.status for ba1ef467 is abandoned/closed with closed_at set; confirm NO other active/queued decommission intent on 2e20605a. Do NOT touch Loacker intents (d3e5b9d1, ef8e3cc5).

CONSTRAINTS: Cody before the canonical-writer change; verbatim body apart from the one-line bypass; no other intent rows touched; verify in a rolled-back tx first; update RPC_REGISTRY.md + CHANGELOG.md + MIGRATIONS_REGISTRY.md + PRD-021 status. NOTE: the WH stock restore (Ritz 12, Hummus 11 on PO-2026-MQ7MQIHO) is already DONE — not in scope. The Popcorn Salted line add+receive is pending a CS-supplied expiry — not in scope.

DONE = abandon_intent bypass shipped (Cody ✓ + migration + local file); intent ba1ef467 closed; no active decommission intent remains on Ritz; registries + PRD status updated.
```
