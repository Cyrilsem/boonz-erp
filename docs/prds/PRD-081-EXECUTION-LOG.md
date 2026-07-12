# PRD-081 Execution Log — Pack-rpc-only guard (WARN)

Run 2026-07-07 overnight, AUTO. **Status: SHIPPED WARN (pack_guard=warn).** Cody PASS
(⚠️→revisions applied). Family A md5 `8587be9a` UNCHANGED.

## Shipped (behind pack_guard, seeded warn)

- `refill_pack_bypass_log` — append-only audit (RLS: select true, no_update, no_delete; Article 7).
- `trg_enforce_pack_via_rpc` BEFORE UPDATE ON refill_dispatching WHEN (packed→true): if the flip
  is NOT via a sanctioned pack RPC (via_rpc<>'true' OR rpc_name NOT IN
  pack_dispatch_line/confirm_packed_transferred) → WARN logs (non-blocking) / ENFORCE raises.

## T-tests (rolled-back trial)

| Test                                                   | Result                                         |
| ------------------------------------------------------ | ---------------------------------------------- |
| WARN: direct pack-flip ⇒ bypass_log +1, write succeeds | PASS                                           |
| sanctioned rpc pack-flip ⇒ bypass_log +0               | PASS                                           |
| ENFORCE: direct pack-flip ⇒ blocked                    | PASS                                           |
| Family A md5 byte-identical                            | PASS (8587be9a)                                |
| conservation delta                                     | 0 (WARN non-blocking; no write-outcome change) |
| cody                                                   | PASS (Article 7 no_update/no_delete added)     |

## Parked (ENFORCE flip — Cody's load-bearing gate)

Flipping pack_guard='enforce' needs a FULL live packing+dispatch+return cycle observed with
ZERO unexpected bypass_log entries, then review the observed rpc_name set and extend the
allowlist (EOD sweep / recovery returns / M2M receive may legitimately flip packed). Do NOT
flip on a partial window. {owner: CS/Ops}

## Status: SHIPPED WARN. ENFORCE flip parked (live-cycle observation).
