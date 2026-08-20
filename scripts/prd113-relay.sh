#!/bin/zsh
# PRD-113 relay — waits for PRD-112 DONE (max 8h), then builds PRD-113 to DONE|BLOCKED.
cd "$(dirname "$0")/.." || exit 1
WAITED=0
while ! grep -q "^## PRD-112 DONE" docs/prds/PRD-112-REPORT.md; do
  if grep -q "^## PRD-112 BLOCKED" docs/prds/PRD-112-REPORT.md; then echo "112 BLOCKED — not starting 113"; exit 5; fi
  WAITED=$((WAITED+300))
  if [ "$WAITED" -gt 28800 ]; then echo "Waited 8h for 112 — giving up"; exit 4; fi
  sleep 300
done
LEGS=0
caffeinate -i zsh -c '
while ! grep -qE "^## PRD-113 (DONE|BLOCKED)" docs/prds/PRD-113-REPORT.md 2>/dev/null; do
  LEGS=$((LEGS+1))
  if [ "$LEGS" -gt 25 ]; then echo "LEG CAP (25) hit — stopping for human review"; exit 3; fi
  claude --model opus -p --dangerously-skip-permissions "You are the PRD-113 build unit. Read docs/prds/PRD-113-inmachine-moves-and-expired-stock-guard.md in full, plus docs/prds/PRD-113-REPORT.md if it exists (resume from its last state; create it otherwise). Branch prd-113-internal-moves-expired-guard. Backend first, Cody review paragraph in the report, then FE. Do NOT git add -A; commit only your own files; do not touch docs/prds/PRD-110* or PRD-112 files or others migrations — add your own new migration files only. All migrations additive. npm run build green before push; merge to main; production verified. Append progress to docs/prds/PRD-113-REPORT.md; final line exactly: ## PRD-113 DONE  (or ## PRD-113 BLOCKED with the Cody verdict). Cody conditions are NOT waivable."
  sleep 60
done
echo "PRD-113 relay finished."
'
