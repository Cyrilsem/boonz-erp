# PRD-085 goal command

GOAL: Execute PRD-085 (docs/prds/PRD-085-finalize-preserve-approved-v2.md) AUTO mode. Self-run Dara/Cody. Keep PRD-085-EXECUTION-LOG.md current. Project ref: eizcexopcuoycuosittm. Depends PRD-076+077+078. PRIOR ART PRD-025 (Closed, fixed via Refill v2) — VERIFY + add regression, do NOT re-fix unless it still reproduces.

HARD GATES: engines md5 byte-identical UNLESS the defect still reproduces and a guard is needed (then Cody signs). diff_vs_golden identical on a no-approval fixture. No change to approve_* semantics. BEGIN..ROLLBACK; forward-only.

WS-1 VERIFY on branch: approve a subset, re-run engine_finalize_pod, confirm approved rows stay approved (reproduce PRD-025 scenario; expect PASS).
WS-2 IF still reproduces: minimal guard — exclude status='approved' from finalize upsert mutation; surface finalize_pending_changes in return payload. ELSE no code change.
WS-3 Add permanent regression to the PRD-076 referee suite: finalize never downgrades approved rows; runs on every future wave.

T-TESTS: T1 approve row + re-finalize different qty => stays approved (+ pending change if guard). T2 partially-approved => only draft rows move. T3 diff_vs_golden identical on no-approval fixture. T4 concurrent approve+finalize => no lost approval. T5 regression registered in referee suite.

CLOSE: CHANGELOG (note verified/no-patch or patched); PRD-085 SHIPPED + EXECUTION-LOG; commit + push. Declares Wave 0c + Wave 0 COMPLETE. ON BLOCKER: append PARKING_LOT.md and continue.
