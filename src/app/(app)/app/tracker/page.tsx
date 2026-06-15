import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { OWNER_EMAIL } from "@/lib/auth/owner";
import TrackerClient, {
  type AgendaItem,
  type Category,
} from "@/app/tracker/tracker-client";

// In-app tracker: renders INSIDE the (app) shell so the sidebar stays visible.
// Owner-only. Non-owner app users are bounced to /app. The standalone /tracker
// route still exists for the (dormant) tracker_boonz partner role, which is
// locked out of /app by middleware.

export const dynamic = "force-dynamic";

export const metadata = {
  title: "Agenda Tracker",
  robots: { index: false, follow: false },
};

export default async function AppTrackerPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login?redirectTo=/app/tracker");
  }

  const isOwner = (user.email ?? "").toLowerCase() === OWNER_EMAIL;

  // Flagged collaborators (e.g. Raffy) get a Boonz-only scope; the owner gets all.
  let trackerBoonzAccess = false;
  if (!isOwner) {
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("tracker_boonz_access")
      .eq("id", user.id)
      .single();
    trackerBoonzAccess = profile?.tracker_boonz_access ?? false;
  }

  if (!isOwner && !trackerBoonzAccess) {
    // Not the owner and not a collaborator: send to the dashboard.
    redirect("/app");
  }

  const allowedCategories: Category[] = isOwner
    ? ["Boonz", "AKY", "Gebran", "Personal"]
    : ["Boonz"];
  const canEditMeta = isOwner; // collaborators: status + notes only
  const canAdd = true; // owner: all categories; collaborator: Boonz only (RLS-enforced)

  const { data: items } = await supabase
    .from("agenda_items")
    .select(
      "id, category, title, status, urgency, due_date, notes, sort_order, cross_cutting",
    )
    .order("category", { ascending: true })
    .order("sort_order", { ascending: true })
    .order("created_at", { ascending: true });

  return (
    <TrackerClient
      initialItems={(items ?? []) as AgendaItem[]}
      allowedCategories={allowedCategories}
      canEditMeta={canEditMeta}
      canAdd={canAdd}
    />
  );
}
