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
    <>
      {/* Plus Jakarta Sans — scoped to /app shell */}
      {/* eslint-disable-next-line @next/next/no-page-custom-font */}
      <style>{`@import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap');`}</style>
      <div
        className="flex h-screen overflow-hidden"
        style={{ fontFamily: "'Plus Jakarta Sans', sans-serif" }}
      >
        <SidebarNav role={role} />
        <main
          className="flex-1 overflow-y-auto"
          style={{ background: "#faf9f7" }}
        >
          {children}
        </main>
      </div>
    </>
  );
}
