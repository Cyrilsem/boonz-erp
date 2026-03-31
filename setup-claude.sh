#!/bin/bash
# ============================================
# Boonz ERP — Claude Code Setup Script
# Run this from your boonz-erp repo root:
#   chmod +x setup-claude.sh && ./setup-claude.sh
# ============================================

set -e

echo "🔧 Setting up Claude Code ecosystem for Boonz ERP..."
echo ""

# ---- Create directory structure ----
mkdir -p .claude/commands
mkdir -p .claude/skills/supabase-patterns
mkdir -p .claude/skills/vox-analytics

echo "📁 Created .claude/ directory structure"

# ---- Commands ----

cat > .claude/commands/spec.md << 'SPEC_EOF'
You are implementing a feature spec. Follow this exact sequence:

BEFORE WRITING CODE:
1. Read the full spec below
2. List every file you will create or modify — get my approval
3. List every database change — get my approval
4. Flag any conflicts with existing code
5. DO NOT proceed until I confirm

WHILE IMPLEMENTING:
- Follow the spec exactly. Do not add, remove, or change scope.
- Make surgical changes. Do not refactor adjacent code.
- If something in the spec is ambiguous, stop and ask.

AFTER IMPLEMENTING:
1. npx tsc --noEmit — fix ALL type errors
2. npm run build — must pass
3. List every file changed with a one-line summary
4. Provide test steps for: operator_admin, field_staff, warehouse

SPEC:
$ARGUMENTS
SPEC_EOF

echo "✅ Created /spec command"

cat > .claude/commands/fix.md << 'FIX_EOF'
Fix this bug. Rules:

1. Find the root cause first. Explain it to me before changing anything.
2. Make the SMALLEST possible fix. Touch the minimum number of files.
3. Do NOT refactor, improve, or clean up surrounding code.
4. Do NOT fix other issues you notice — just this one.
5. npx tsc --noEmit after the fix
6. Tell me exactly what you changed, which files, and why

BUG:
$ARGUMENTS
FIX_EOF

echo "✅ Created /fix command"

cat > .claude/commands/migrate.md << 'MIGRATE_EOF'
Write a Supabase SQL migration. Rules:

- RLS policies: always (SELECT auth.uid()), never bare auth.uid()
- NEVER reference user_profiles in RLS policies for other tables
- user_profiles RLS: only own_profile_select and own_profile_update, both id = (SELECT auth.uid())
- Include rollback SQL as comments at the bottom
- Place the file in supabase/migrations/
- Name format: YYYYMMDDHHMMSS_description.sql
- After writing, explain what the migration does and any risks
- Do NOT run the migration — just write the file

MIGRATION DESCRIPTION:
$ARGUMENTS
MIGRATE_EOF

echo "✅ Created /migrate command"

cat > .claude/commands/review.md << 'REVIEW_EOF'
Review the current state of the codebase area described below.

DO NOT MAKE ANY CHANGES. This is read-only.

Report:
1. What exists and works correctly
2. What is broken, buggy, or incomplete
3. What is missing entirely
4. Technical debt or risks
5. Recommended next steps, ordered by priority and effort

AREA TO REVIEW:
$ARGUMENTS
REVIEW_EOF

echo "✅ Created /review command"

# ---- Skills ----

cat > .claude/skills/supabase-patterns/SKILL.md << 'SUPA_EOF'
# Supabase Patterns for Boonz ERP

## RLS Policy Template (standard table)
```sql
-- Read: admin + warehouse can read all, field_staff reads own
CREATE POLICY "table_select" ON public.table_name
FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
    AND role IN ('operator_admin', 'warehouse')
  )
  OR created_by = (SELECT auth.uid())
);

-- Write: admin only
CREATE POLICY "table_insert" ON public.table_name
FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = (SELECT auth.uid())
    AND role = 'operator_admin'
  )
);
```

## user_profiles — DANGER ZONE
Only these two policies. Nothing else. Ever.
```sql
CREATE POLICY "own_profile_select" ON public.user_profiles
FOR SELECT USING (id = (SELECT auth.uid()));

CREATE POLICY "own_profile_update" ON public.user_profiles
FOR UPDATE USING (id = (SELECT auth.uid()));
```
Adding ANY policy that queries user_profiles from another table's RLS will cause infinite recursion → null auth → all users route to driver home.

## Row Limits
Supabase default returns max 1,000 rows. Always add .limit(10000).
product_mapping: up to 223 rows/machine — scope per-machine + .limit(10000).

## Migration File Convention
- Path: supabase/migrations/YYYYMMDDHHMMSS_description.sql
- Always include rollback as SQL comments at bottom
- Test with all 3 roles before marking complete

## Edge Functions
Require both headers: Authorization: Bearer {token} AND apikey: {anon_key}.
For simple DB writes, skip Edge Functions — use direct Supabase client inserts instead.

## FIFO Inventory
```typescript
const { data: batches } = await supabase
  .from('inventory_batches')
  .select('*')
  .eq('product_id', productId)
  .gt('quantity', 0)
  .order('expiration_date', { ascending: true, nullsFirst: false })
  .limit(10000);
// Walk batches in order, deducting from each until quantity fulfilled
```
SUPA_EOF

echo "✅ Created supabase-patterns skill"

cat > .claude/skills/vox-analytics/SKILL.md << 'VOX_EOF'
# VOX Cinema Analytics for Boonz

## Data Model
Two data sources joined at the transaction level:
- POS machine export: what the machine sold (quantity, product, total amount)
- Adyen payment export: what was actually captured (payment status, wallet type)

Join key: Adyen "Merchant Reference" = POS "Internal Transaction S/N"
Strip the _N suffix from the POS S/N to get txn_base for matching.

## Sites
- Mercato: store key VOXMM, 2 machines (Machine 1 = VOX, Machine 2 = Boonz)
- Mirdif City Centre: store key VOXMCC
- Exclude pre-Feb 6 transactions (test period)

## Key Metrics
- Default rate: (Total amount - Captured Amount) / Total amount × 100
- Total amount is the correct sales baseline (NOT Paid amount)
- Current rates: overall 2.23%, Mercato 4.2%, Mirdif 1.1%

## Dashboard Structure (6 tabs)
1. Overview — KPIs, revenue trend, daily avg transactions
2. Sites & Machines — site comparison, per-machine breakdown
3. Products — volume vs value bubble chart, top products
4. Eid Analysis — holiday period performance
5. Payments — wallet types, payment methods
6. Transactions — ONLY tab showing both Total Sales AND Captured Amount side by side

All tabs except Transactions use Total amount exclusively.

## Supabase Migration Plan (NOT YET EXECUTED)
13 tables: 2 raw staging + 11 analytics
ETL pipeline: Python (run_etl.py) → Supabase tables → TypeScript lib (vox-data.ts) → API route (/api/vox/dashboard) → Page (/app/vox)
Existing state: adyen_transactions has 9,930 rows, needs token_payment_variant column added.
VOX_EOF

echo "✅ Created vox-analytics skill"

# ---- Settings (hooks) ----

cat > .claude/settings.json << 'SETTINGS_EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "npx prettier --write \"$FILE_PATH\" 2>/dev/null || true"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

echo "✅ Created settings.json with auto-format hook"

# ---- Summary ----

echo ""
echo "============================================"
echo "✅ Claude Code setup complete!"
echo ""
echo "Structure created:"
echo ""
echo "  .claude/"
echo "  ├── settings.json              (auto-format hook)"
echo "  ├── commands/"
echo "  │   ├── spec.md                /spec — implement a feature"
echo "  │   ├── fix.md                 /fix — surgical bug fix"
echo "  │   ├── migrate.md             /migrate — Supabase migration"
echo "  │   └── review.md              /review — read-only code review"
echo "  └── skills/"
echo "      ├── supabase-patterns/"
echo "      │   └── SKILL.md           RLS, FIFO, limits, migrations"
echo "      └── vox-analytics/"
echo "          └── SKILL.md           data model, metrics, ETL plan"
echo ""
echo "Next steps:"
echo "  1. Review CLAUDE.md in repo root (update separately)"
echo "  2. git add .claude/"
echo "  3. git commit -m 'chore: claude code ecosystem setup'"
echo "  4. git push"
echo "  5. Open Claude Code and test: /review app/dashboard"
echo "============================================"
