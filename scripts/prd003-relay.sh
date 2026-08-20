#!/bin/zsh
# PRD-003 relay — PO document totals / VAT / additions fold-in. Halts on "## PRD-003 DONE|BLOCKED".
cd "$(dirname "$0")/.." || exit 1
LEGS=0
caffeinate -i zsh -c '
while ! grep -qE "^## PRD-003 (DONE|BLOCKED)" docs/prds/procurement/PRD-003-REPORT.md 2>/dev/null; do
  LEGS=$((LEGS+1))
  if [ "$LEGS" -gt 25 ]; then echo "LEG CAP (25) hit — stopping for human review"; exit 3; fi
  claude --model opus -p --dangerously-skip-permissions "You are the PRD-003 build unit. Read docs/prds/procurement/PRD-003-po-document-totals-vat-discount.md IN FULL — sections 12 (CS rulings + scope addition) and 13 (execution notes) are binding. Also read docs/prds/procurement/PRD-003-REPORT.md if it exists and resume from its last state; create it otherwise. Branch prd-003-po-document-totals. Dara schema review then Cody constitutional review, paragraphs in the report, conditions NOT waivable. Additive migrations only, own files only, do not touch other PRDs files or PRD-110 loop files, no git add -A. The T11 regression (warehouse_inventory cost = ex-VAT unit price) is the gate that protects partner settlements. golden run_all green, npm run build green, merge to main, production verified. Append progress to docs/prds/procurement/PRD-003-REPORT.md; final line exactly: ## PRD-003 DONE  (or ## PRD-003 BLOCKED with the verdict)."
  sleep 60
done
echo "PRD-003 relay finished."
'
