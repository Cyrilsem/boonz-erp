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
