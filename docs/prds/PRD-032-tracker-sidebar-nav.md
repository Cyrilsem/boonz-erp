# PRD-032: Tracker sidebar nav entry

Owner: CS
Date: 2026-06-15
Surface: Front end only (Next.js app shell). No DB, no RPC, no migration.
Governance: Stax FE. No Cody (touches no protected entity, no SECURITY DEFINER, no DDL). Forward-only. Deploy to Vercel after CS sign-off. No em dashes.

## Objective

Add a "Tracker" item to the `/app` left sidebar, positioned immediately after "Sales Pipeline", that links to `/tracker`. The item is visible only to the tracker owner (cyrilsem@gmail.com). No other app user sees it.

## Why

The agenda tracker already lives at `/tracker` (owner gated at the page and the data layer). Today it is reachable only by typing the URL. CS wants a one click entry from the app shell. Because `/tracker` redirects anyone who is not the owner, the menu item must be owner only so other app users (operator_admin, manager, finance, warehouse) never see a link that would bounce them to login.

## Current state (verified live 2026-06-15, do not re-diagnose)

- Nav is declarative in `src/app/(app)/sidebar-nav.tsx`: an `allNavItems: NavItem[]` array rendered in order, filtered by `hiddenByRole[role]` (label based). `SidebarNav` currently receives only `{ role: string }`.
- "Sales Pipeline" is `{ label: "Sales Pipeline", href: "/app/sales-pipeline", icon: "◎" }`, second to last, followed by "Settings".
- `src/app/(app)/layout.tsx` already fetches the Supabase `user` (so `user.email` is available) and the `role` from `user_profiles`, then renders `<SidebarNav role={role} />`.
- `/tracker` (`src/app/tracker/page.tsx`) is gated to `cyrilsem@gmail.com` (owner) and the dormant `tracker_boonz` role. The page sits outside the `(app)` layout and renders its own full screen shell. This PRD does not change any of that gating.

## Scope

In scope: one nav entry, owner only visibility, correct ordering. Out of scope: any change to `/tracker` access control, the tracker UI, or RLS.

## Build order (Stax FE)

1. `src/app/(app)/sidebar-nav.tsx`
   - Extend the `NavItem` interface with an optional `ownerOnly?: boolean`.
   - Insert, directly after the "Sales Pipeline" entry in `allNavItems`:
     `{ label: "Tracker", href: "/tracker", icon: "✓", ownerOnly: true }`.
   - Change the component signature to `SidebarNav({ role, isOwner }: { role: string; isOwner: boolean })`.
   - After the existing role filter, also drop owner only items when not owner:
     `items = items.filter((item) => !item.ownerOnly || isOwner)`.
   - The active state highlight needs no change; `/tracker` renders outside this layout so the sidebar is not shown there.

2. `src/app/(app)/layout.tsx`
   - Compute `const isOwner = (user?.email ?? "").toLowerCase() === OWNER_EMAIL;`
   - Pass it through: `<SidebarNav role={role} isOwner={isOwner} />`.

3. Owner email constant (DRY, recommended)
   - Create `src/lib/auth/owner.ts` exporting `export const OWNER_EMAIL = "cyrilsem@gmail.com";`
   - Import it in both `layout.tsx` and `src/app/tracker/page.tsx` (replace the local `OWNER_EMAIL` literal there) so the owner identity lives in one place. If skipped, inline the literal in `layout.tsx` and note the duplication.

## Acceptance criteria

- Logged in as cyrilsem@gmail.com, the sidebar shows "Tracker" immediately after "Sales Pipeline" and before "Settings"; clicking it opens `/tracker`.
- Logged in as any other app user (operator_admin, manager, finance, warehouse), the "Tracker" item is absent.
- No console errors; collapsed sidebar shows the icon only, consistent with the other items.
- `/tracker` page level gating is unchanged: a non owner who somehow navigates to `/tracker` is still redirected to login.
- `npx tsc --noEmit` clean. No DB or RPC changes. Build deploys on Vercel.

## Done when

Type check green, the item renders for the owner only, behavior verified in preview, change committed on its own, and deployed to production on `main`.
