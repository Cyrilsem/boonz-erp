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
  .from("inventory_batches")
  .select("*")
  .eq("product_id", productId)
  .gt("quantity", 0)
  .order("expiration_date", { ascending: true, nullsFirst: false })
  .limit(10000);
// Walk batches in order, deducting from each until quantity fulfilled
```
