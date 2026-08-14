#!/bin/zsh
# PRD-115 relay — mid-pack plan edit safety. Halts on "## PRD-115 DONE|BLOCKED".
cd "$(dirname "$0")/.." || exit 1
LEGS=0
caffeinate -i zsh -c '
while ! grep -qE "^## PRD-115 (DONE|BLOCKED)" docs/prds/PRD-115-REPORT.md 2>/dev/null; do
  LEGS=$((LEGS+1))
  if [ "$LEGS" -gt 25 ]; then echo "LEG CAP (25) hit — stopping for human review"; exit 3; fi
  claude --model opus -p --dangerously-skip-permissions "You are the PRD-115 build unit. Read docs/prds/PRD-115-midpack-plan-edit-safety.md IN FULL, plus docs/prds/PRD-115-REPORT.md if it exists (resume; create otherwise). Branch prd-115-midpack-safety. Backend first (tombstones in remove_dispatch_row + push_plan_to_dispatch guard + needs_reconfirm state), Cody review paragraph in the report, conditions NOT waivable, then the /field packing FE (single refresh banner, needs_reconfirm CTA, honest pick validation). Guards stay byte-identical except as specified. Own migration files only; no git add -A; do not touch other PRDs files. Use the one-fixture-per-tick golden runner. run_all green, npm run build green, merge to main, production verified. Append progress to docs/prds/PRD-115-REPORT.md; final line exactly: ## PRD-115 DONE  (or ## PRD-115 BLOCKED with the verdict)."
  sleep 60
done
echo "PRD-115 relay finished."
'
