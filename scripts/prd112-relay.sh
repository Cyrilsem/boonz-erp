#!/bin/zsh
# PRD-112 relay — resumes at Unit 7 (FE). Halts on "## PRD-112 DONE" or "## PRD-112 BLOCKED".
cd "$(dirname "$0")/.." || exit 1
REPORT="docs/prds/PRD-112-REPORT.md"
LEGS=0
caffeinate -i zsh -c '
while ! grep -qE "^## PRD-112 (DONE|BLOCKED)" docs/prds/PRD-112-REPORT.md; do
  LEGS=$((LEGS+1))
  if [ "$LEGS" -gt 25 ]; then echo "LEG CAP (25) hit — stopping for human review"; exit 3; fi
  claude --model opus -p --dangerously-skip-permissions "You are the PRD-112 build unit. Read docs/prds/PRD-112-driver-substitution-and-day-close.md in full, then docs/prds/PRD-112-REPORT.md in full. Units 1-6 (backend) are DONE and applied to the live DB. Resume at Unit 7: the FE — the Change Product button + modal in /field packing and driver views (spec 3.2), the Day Close tab on /refill (spec 3.3), and the duplicate-guard message line. Branch prd-112-driver-substitution. Do NOT git add -A; commit only your own files. Do not touch docs/prds/PRD-110* or other PRDs migrations. npm run build must be green before push. Walk the Vercel preview, then merge to main. Append progress to docs/prds/PRD-112-REPORT.md; when all acceptance criteria pass, append the exact line: ## PRD-112 DONE  (or ## PRD-112 BLOCKED with the reason). Cody conditions are NOT waivable."
  sleep 60
done
echo "PRD-112 relay finished."
'
