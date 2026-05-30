import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import TrackerClient, { type AgendaItem } from "./tracker-client";

// Hard owner gate. Only this account may ever load /tracker. Anyone else
// (including other authenticated Boonz users) is bounced. RLS on
// agenda_items enforces the same rule at the data layer as defence in depth.
const OWNER_EMAIL = "cyrilsem@gmail.com";

export const dynamic = "force-dynamic";

export const metadata = {
  title: "Agenda Tracker",
  robots: { index: false, follow: false },
};

export default async function TrackerPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login?redirectTo=/tracker");
  }
  if ((user.email ?? "").toLowerCase() !== OWNER_EMAIL) {
    // Not the owner: do not reveal the page exists.
    redirect("/login?redirectTo=/tracker&error=forbidden");
  }

  const { data: items } = await supabase
    .from("agenda_items")
    .select("id, category, title, status, urgency, due_date, notes, sort_order")
    .order("category", { ascending: true })
    .order("sort_order", { ascending: true })
    .order("created_at", { ascending: true });

  return <TrackerClient initialItems={(items ?? []) as AgendaItem[]} />;
}
