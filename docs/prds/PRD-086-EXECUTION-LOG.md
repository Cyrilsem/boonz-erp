# PRD-086 - EXECUTION LOG

Run: 2026-07-07, Claude Fable 5. Scope: src/app/(app)/refill/DailyDispatchingTab.tsx ONLY (FE read path). Zero RPC/view/migration/write-path changes.

## Change

- Query now also selects pack_outcome, returned, skipped; DispatchLine typed accordingly.
- Per-machine aggregate adds fillable_total (lines where NOT (pack_outcome='not_filled' OR returned OR skipped)) and not_filled_count; total/packed_count/picked_up_count/dispatched_count unchanged.
- getMachineStage, the PACKED/PICKED UP/DISPATCHED machine counters, the progress bar denominator, and allDone all measure against fillable_total; fillable_total 0 = complete.
- Deliberate deviation from the PRD's literal `===`: comparisons use `>=` and the bar clamps at 100. Reason, proven on live 07-07 data: returned lines can carry dispatched=true and bulk "Mark All ..." flags every include line, so stage counts EXCEED the fillable denominator (AMZ-1068: 27 dispatched vs 23 fillable; MC-2004: 19 vs 18; VOXMM-1013: 7 vs 6). Strict equality would leave 3 of the 7 machines incomplete - the same false negative the PRD exists to kill.
- Chips read P/U/D {count}/{fillable_total} plus a muted "· N not filled" when present. not_filled rows are NEVER flipped to packed/dispatched anywhere (detail-row icons untouched, bulk-update payloads untouched).

## Verification

- Live replication SQL (read-only, dispatch_date 2026-07-07): AMZ-1029 17/17, AMZ-1038 24/24, AMZ-1057 12/12, AMZ-1068 27>=23, MC-2004 19>=18, OMDBB-1020 16/16, VOXMM-1013 7>=6 -> ALL 7 machines complete; board reads 7/7 / 7/7 / 7/7, bars 100%.
- Mid-pack behaviour preserved: a fillable line with packed=false keeps packed_count < fillable_total -> stage "pack", card incomplete, counter excludes the machine.
- npx tsc --noEmit green. npm run lint: 98 pre-existing repo error lines, identical with the change stashed vs applied (zero introduced).
- mark-all-dispatched -> receive_all_dispatches_for_machine path untouched.

## Ship

Branch fix/prd-086-dispatch-completion-counter -> merged to main -> pushed (Vercel auto-deploys main; deploy recorded in docs/DEPLOYMENTS.md by the record-prod-deploy workflow). Rollback: revert the merge commit and push.

## CLOSED 2026-07-10

Shipped to prod in 1b0bb8c (deploy recorded 619911e). Board reads terminal-state completion; no follow-ups.
