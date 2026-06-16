#!/usr/bin/env bash
# deploy-status.sh - one view of where everything stands across the 3 deploy layers.
# Run from the repo root:  bash scripts/deploy-status.sh
# Layer 1 = Git (code in repo)   Layer 2 = Supabase (DB)   Layer 3 = Vercel (FE)
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

line(){ printf '%s\n' "------------------------------------------------------------"; }

echo "============================================================"
echo " BOONZ DEPLOY STATUS  -  $(date '+%Y-%m-%d %H:%M')"
echo "============================================================"

# ---------- LAYER 1: GIT ----------
echo
echo "LAYER 1  GIT (code)"; line
git fetch origin --quiet 2>/dev/null || echo "  (fetch failed - showing last-known refs)"
cur=$(git branch --show-current)
lm=$(git rev-parse --short main 2>/dev/null); om=$(git rev-parse --short origin/main 2>/dev/null)
a=$(git rev-list --count origin/main..main 2>/dev/null); b=$(git rev-list --count main..origin/main 2>/dev/null)
printf "  current branch : %s\n" "$cur"
printf "  main %s   origin/main %s   (main %s ahead / %s behind)\n" "$lm" "$om" "$a" "$b"
echo "  branches with work NOT on origin/main:"
git for-each-ref --format='%(refname:short)' refs/heads | while read -r br; do
  n=$(git rev-list --count origin/main.."$br" 2>/dev/null || echo 0)
  if [ "$n" -gt 0 ]; then
    tip=$(git log -1 --format='%h %s' "$br" 2>/dev/null)
    printf "    - %-38s %s unmerged | tip: %s\n" "$br" "$n" "$tip"
  fi
done
md=$(git diff --name-only | wc -l | tr -d ' '); ut=$(git ls-files --others --exclude-standard | wc -l | tr -d ' '); st=$(git stash list | wc -l | tr -d ' ')
printf "  uncommitted: %s tracked modified, %s untracked | stashes: %s\n" "$md" "$ut" "$st"

# ---------- LAYER 2: SUPABASE (DB) ----------
echo
echo "LAYER 2  SUPABASE (DB migrations)"; line
if command -v supabase >/dev/null 2>&1; then
  echo "  supabase migration list (Local = file in repo, Remote = applied on prod DB):"
  supabase migration list 2>&1 | sed 's/^/    /' | tail -25
  echo "    >> Any row with a Local timestamp but BLANK Remote = in repo, NOT applied to prod."
else
  echo "  supabase CLI not found. Files in repo not yet confirmed-applied:"
  ls -1 supabase/migrations 2>/dev/null | tail -15 | sed 's/^/    /'
  echo "    >> install supabase CLI then re-run, or check the dashboard migration history."
fi

# ---------- LAYER 3: VERCEL (FE) ----------
echo
echo "LAYER 3  VERCEL (FE deploy)"; line
printf "  origin/main commit that SHOULD be live: %s\n" "$om"
if command -v vercel >/dev/null 2>&1; then
  echo "  latest production deployment:"
  vercel ls --prod 2>/dev/null | head -4 | sed 's/^/    /'
  echo "    >> compare the deployed commit to origin/main above. If older, prod FE is behind."
else
  echo "  vercel CLI not found. Confirm in the Vercel dashboard that the latest"
  echo "  Production deployment is built from origin/main commit $om."
fi
echo
echo "DONE. Backend(DB) and FE(Vercel) are SEPARATE ships from the git commit."
