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
  if (!isOwner) {
    // Only the owner gets the in-app tracker; send everyone else to the dashboard.
    redirect("/app");
  }

  const allowedCategories: Category[] = ["Boonz", "AKY", "Gebran", "Personal"];

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
      canEditMeta={true}
      canAdd={true}
    />
  );
}
