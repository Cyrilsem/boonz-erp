import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { OWNER_EMAIL } from "@/lib/auth/owner";
import TrackerClient, {
  type AgendaItem,
  type Category,
} from "./tracker-client";

// Access model:
//  - OWNER (cyrilsem@gmail.com): full tracker, all categories, full edit.
//  - tracker_boonz partner (e.g. Raffy): Boonz column only, status + notes only.
// RLS on agenda_items enforces the same data scope as defence in depth.
// OWNER_EMAIL is shared with the (app) layout via @/lib/auth/owner.

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

  const isOwner = (user.email ?? "").toLowerCase() === OWNER_EMAIL;

  let role: string | null = null;
  if (!isOwner) {
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    role = profile?.role ?? null;
  }

  // Only the owner and tracker_boonz partners may load this page.
  if (!isOwner && role !== "tracker_boonz") {
    redirect("/login?redirectTo=/tracker&error=forbidden");
  }

  const allowedCategories: Category[] = isOwner
    ? ["Boonz", "AKY", "Gebran", "Personal"]
    : ["Boonz"];
  const canEditMeta = isOwner; // partners: status + notes only
  const canAdd = true; // owner: all; tracker_boonz: Boonz only (enforced by RLS)

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
