# /goal - PRD-032 Tracker sidebar nav entry

Paste into Claude Code in the `boonz-erp` repo. Single /goal run. FE only, no DB. Stax FE, no Cody (no protected entity, no DDL, no SECURITY DEFINER). Forward-only. No em dashes. Do not change `/tracker` access control. Apply nothing to prod without CS sign-off: build, show diff, STOP before deploy.

---

/goal Implement PRD-032 per docs/prds/PRD-032-tracker-sidebar-nav.md. Objective: add a "Tracker" item to the /app left sidebar, immediately after "Sales Pipeline", linking to /tracker, visible only to the owner (cyrilsem@gmail.com). No other app user sees it. No change to /tracker page gating, no DB, no RPC, no migration.

STATE (verified live 2026-06-15, do not re-diagnose): Nav is declarative in src/app/(app)/sidebar-nav.tsx via allNavItems: NavItem[], rendered in order, filtered by hiddenByRole[role] (label based). SidebarNav currently takes only { role: string }. "Sales Pipeline" = { label: "Sales Pipeline", href: "/app/sales-pipeline", icon: "◎" }, second to last, before "Settings". src/app/(app)/layout.tsx already fetches the Supabase user (user.email available) and role from user_profiles, then renders <SidebarNav role={role} />. /tracker (src/app/tracker/page.tsx) is owner gated by email (cyrilsem@gmail.com) plus the dormant tracker_boonz role, and renders outside the (app) layout. The menu entry must be owner only because /tracker bounces non owners to login.

BUILD ORDER:

1. src/app/(app)/sidebar-nav.tsx: add optional ownerOnly?: boolean to the NavItem interface. Insert directly after the Sales Pipeline entry in allNavItems: { label: "Tracker", href: "/tracker", icon: "✓", ownerOnly: true }. Change the component signature to SidebarNav({ role, isOwner }: { role: string; isOwner: boolean }). After the existing role based filter, also drop owner only items when not owner: items = items.filter((item) => !item.ownerOnly || isOwner). No active state change needed.

2. src/app/(app)/layout.tsx: compute const isOwner = (user?.email ?? "").toLowerCase() === OWNER_EMAIL; and pass it: <SidebarNav role={role} isOwner={isOwner} />.

3. DRY owner constant (recommended): create src/lib/auth/owner.ts exporting export const OWNER_EMAIL = "cyrilsem@gmail.com"; import it in layout.tsx and in src/app/tracker/page.tsx, replacing the local literal there. If you skip this, inline the literal in layout.tsx and note the duplication.

VERIFY:

- As cyrilsem@gmail.com: "Tracker" appears immediately after "Sales Pipeline", before "Settings"; clicking opens /tracker.
- As any other app user (operator_admin, manager, finance, warehouse): "Tracker" is absent.
- Collapsed sidebar shows the icon only, consistent with siblings.
- /tracker page gating unchanged: a non owner navigating to /tracker is still redirected to login.
- npx tsc --noEmit clean.

DONE WHEN: type check green, owner only visibility confirmed in preview, change committed on its own branch/commit, then deployed to production on main after CS sign-off. Show me the diff and the preview behavior before pushing to main. No DB changes in this PRD.
