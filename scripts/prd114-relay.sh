#!/bin/zsh
# PRD-114 relay — driver visit checklist (expired in red). Waits for PRD-003 DONE (max 8h), then builds.
cd "$(dirname "$0")/.." || exit 1
WAITED=0
while ! grep -q "^## PRD-003 DONE" docs/prds/procurement/PRD-003-REPORT.md 2>/dev/null; do
  if grep -q "^## PRD-003 BLOCKED" docs/prds/procurement/PRD-003-REPORT.md 2>/dev/null; then echo "003 BLOCKED — not starting 114"; exit 5; fi
  WAITED=$((WAITED+300))
  if [ "$WAITED" -gt 28800 ]; then echo "Waited 8h for 003 — giving up"; exit 4; fi
  sleep 300
done
LEGS=0
caffeinate -i zsh -c '
while ! grep -qE "^## PRD-114 (DONE|BLOCKED)" docs/prds/PRD-114-REPORT.md 2>/dev/null; do
  LEGS=$((LEGS+1))
  if [ "$LEGS" -gt 25 ]; then echo "LEG CAP (25) hit — stopping for human review"; exit 3; fi
  claude --model opus -p --dangerously-skip-permissions "You are the PRD-114 build unit. Read docs/prds/PRD-114-driver-visit-checklist-expired-red.md IN FULL, plus docs/prds/PRD-114-REPORT.md if it exists (resume; create otherwise). Branch prd-114-visit-checklist. Backend read RPC first, Cody review paragraph in the report (conditions NOT waivable), then FE. pod_inventory is READ ONLY except the canonical write-off fired at day-close acknowledge. Own migration files only; no git add -A; do not touch other PRDs files. Use the one-fixture-per-tick golden runner (PRD-003 rebuilt it). run_all green, npm run build green, merge to main, production verified. Append progress to docs/prds/PRD-114-REPORT.md; final line exactly: ## PRD-114 DONE  (or ## PRD-114 BLOCKED with the verdict)."
  sleep 60
done
echo "PRD-114 relay finished."
'
