// PRD-140 Item 4: access provider + hook.
//
// getUserAccess is server-side (any Server Component / layout, passed an
// already-created Supabase server client). AccessProvider/useAccess/
// useRequireArea are client-side: the provider fetches v_my_access once on
// mount and caches it in context so no page re-fetches it.
//
// This item mounts the provider but changes no page's behaviour yet (Item 7
// is what replaces the hard-coded *_ROLES arrays with useRequireArea).

"use client";

import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export interface AccessArea {
  area_key: string;
  surface: "app" | "field";
  route_prefix: string | null;
  sidebar_label: string | null;
}

// ─── Server ─────────────────────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type ServerSupabaseClient = any;

export async function getUserAccess(
  supabaseServerClient: ServerSupabaseClient,
  userId: string,
): Promise<AccessArea[]> {
  const { data, error } = await supabaseServerClient
    .from("v_my_access")
    .select("area_key, surface, route_prefix, sidebar_label");
  if (error) {
    console.error(`[getUserAccess] failed for user ${userId}:`, error.message);
    return [];
  }
  return (data ?? []) as AccessArea[];
}

// ─── Client ─────────────────────────────────────────────────────────────────

interface AccessContextValue {
  areas: AccessArea[];
  loading: boolean;
  has: (key: string) => boolean;
  refresh: () => Promise<void>;
}

const AccessContext = createContext<AccessContextValue | null>(null);

export function AccessProvider({ children }: { children: React.ReactNode }) {
  const [areas, setAreas] = useState<AccessArea[]>([]);
  const [loading, setLoading] = useState(true);

  async function load() {
    const supabase = createClient();
    const { data, error } = await supabase
      .from("v_my_access")
      .select("area_key, surface, route_prefix, sidebar_label");
    if (error) {
      console.error("[AccessProvider] v_my_access read failed:", error.message);
      setAreas([]);
    } else {
      setAreas((data ?? []) as AccessArea[]);
    }
    setLoading(false);
  }

  useEffect(() => {
    load();
    // Fetched once on mount, matching this item's own spec ("fetches
    // v_my_access once on mount, caches in context"). `refresh()` below is
    // the escape hatch for a caller that just changed its own access (e.g.
    // right after an admin edits their own overrides) and needs it re-read.
  }, []);

  const has = useMemo(() => {
    const keys = new Set(areas.map((a) => a.area_key));
    return (key: string) => keys.has(key);
  }, [areas]);

  const value = useMemo<AccessContextValue>(
    () => ({ areas, loading, has, refresh: load }),
    [areas, loading, has],
  );

  return (
    <AccessContext.Provider value={value}>{children}</AccessContext.Provider>
  );
}

export function useAccess(): AccessContextValue {
  const ctx = useContext(AccessContext);
  if (!ctx) {
    throw new Error("useAccess() must be used within an AccessProvider");
  }
  return ctx;
}

export function useRequireArea(key: string, redirectTo?: string): boolean {
  const { has, loading, areas } = useAccess();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    if (!has(key)) {
      const surface = key.startsWith("field.") ? "/field" : "/app";
      router.replace(redirectTo ?? surface);
    }
    // areas is read via has(); included so a later override change (the
    // same user re-resolving mid-session) re-evaluates the redirect.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loading, key, redirectTo, areas]);

  return !loading && has(key);
}
