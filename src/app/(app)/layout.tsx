import { createClient } from "@/lib/supabase/server";
import SidebarNav from "./sidebar-nav";

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  let role = "operator_admin";
  if (user) {
    const { data: profile } = await supabase
      .from("user_profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    role = profile?.role ?? "operator_admin";
  }

  return (
    <div className="flex h-screen overflow-hidden">
      <SidebarNav role={role} />
      <main className="flex-1 overflow-y-auto">{children}</main>
    </div>
  );
}
