---
ticket: STAX-2026-05-31-01
title: Re-test Hunter Truffle variant-split on /field/dispatching post PRD-011
owner: Stax
opened: 2026-05-30
source: PROGRAM-2026-05-31 Bucket E2
severity: P2
---

# Re-test Hunter Truffle variant-split on /field/dispatching

Reported 21/05/26 (OMDCW-1021): the returned-items variant-split UI errored when
splitting a Hunter Black Truffle return across variants on /field/dispatching.

PRD-011 (repair_unbound_dispatch / variant handling) shipped since. This ticket:
re-test the Hunter Truffle variant-split flow on /field/dispatching and confirm
whether the 21/05 error still reproduces.

Repro (per 21/05/26 doc):

1. Open /field/dispatching for OMDCW-1021 (or any machine with a Hunter Black
   Truffle Remove line that has multiple expiry batches).
2. Attempt the variant-split return (split the Remove qty across the batches).
3. Observe the UI error reported on 21/05.

If it still reproduces: fix the FE handler (variant-split path) and add a test.
If resolved by PRD-011: close this ticket as fixed-by-PRD-011.

Note: not attempted in the PROGRAM-2026-05-31 run (FE re-test needs the running
app, not a SQL session).
