"use client";

// Phase G PRD v2 Phase 1 FE wiring.
//
// React context for the open inventory-control session. One open session per
// user is the contract enforced by start_inventory_session (auto-aborts any
// prior open session). Surfacing the session id to every inventory route via
// context means the cell edits do not need to thread session_id through props.
//
// Session state survives client-side navigation. Persisted to sessionStorage
// so a hard refresh in the middle of a sitting does not lose the session id.
// On the next mount we sanity-check the persisted session by querying
// inventory_control_session.status and dropping if not 'open'.

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { createClient } from "@/lib/supabase/client";
import {
  closeInventorySession,
  startInventorySession,
  type SessionHandle,
} from "./attempt-rpcs";

const STORAGE_KEY = "phaseG.inventoryControlSession.v1";

interface PersistedSession {
  session_id: string;
  session_slug: string | null;
  scope_warehouse_id: string;
  started_at: string;
  started_by_role: string | null;
}

interface InventorySessionContextValue {
  session: PersistedSession | null;
  starting: boolean;
  closing: boolean;
  error: string | null;
  start: (args: {
    warehouseId: string;
    slug?: string | null;
    productIds?: string[] | null;
    role?: string | null;
  }) => Promise<PersistedSession | null>;
  close: (summary?: Record<string, unknown>) => Promise<void>;
  refresh: () => Promise<void>;
}

const Ctx = createContext<InventorySessionContextValue | null>(null);

function readPersisted(): PersistedSession | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as PersistedSession;
    if (!parsed?.session_id) return null;
    return parsed;
  } catch {
    return null;
  }
}

function writePersisted(s: PersistedSession | null) {
  if (typeof window === "undefined") return;
  if (s == null) {
    window.sessionStorage.removeItem(STORAGE_KEY);
  } else {
    window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  }
}

export function InventorySessionProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const [session, setSession] = useState<PersistedSession | null>(null);
  const [starting, setStarting] = useState(false);
  const [closing, setClosing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Re-hydrate from sessionStorage on mount, then verify the row is still open.
  useEffect(() => {
    const persisted = readPersisted();
    if (!persisted) return;
    setSession(persisted);
    const supabase = createClient();
    (async () => {
      const { data } = await supabase
        .from("inventory_control_session")
        .select("status")
        .eq("session_id", persisted.session_id)
        .single();
      if (!data || data.status !== "open") {
        writePersisted(null);
        setSession(null);
      }
    })();
  }, []);

  const start = useCallback<InventorySessionContextValue["start"]>(
    async ({ warehouseId, slug, productIds, role }) => {
      setError(null);
      setStarting(true);
      try {
        const supabase = createClient();
        const handle: SessionHandle = await startInventorySession(supabase, {
          scopeWarehouseId: warehouseId,
          scopeProductIds: productIds ?? null,
          sessionSlug: slug ?? null,
        });
        const next: PersistedSession = {
          session_id: handle.session_id,
          session_slug: handle.session_slug,
          scope_warehouse_id: handle.scope_warehouse_id,
          started_at: new Date().toISOString(),
          started_by_role: role ?? null,
        };
        writePersisted(next);
        setSession(next);
        return next;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setError(msg);
        return null;
      } finally {
        setStarting(false);
      }
    },
    [],
  );

  const close = useCallback<InventorySessionContextValue["close"]>(
    async (summary) => {
      if (!session) return;
      setError(null);
      setClosing(true);
      try {
        const supabase = createClient();
        await closeInventorySession(supabase, session.session_id, summary);
        writePersisted(null);
        setSession(null);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setError(msg);
      } finally {
        setClosing(false);
      }
    },
    [session],
  );

  const refresh = useCallback<
    InventorySessionContextValue["refresh"]
  >(async () => {
    if (!session) return;
    const supabase = createClient();
    const { data } = await supabase
      .from("inventory_control_session")
      .select("status")
      .eq("session_id", session.session_id)
      .single();
    if (!data || data.status !== "open") {
      writePersisted(null);
      setSession(null);
    }
  }, [session]);

  const value = useMemo<InventorySessionContextValue>(
    () => ({ session, starting, closing, error, start, close, refresh }),
    [session, starting, closing, error, start, close, refresh],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useInventorySession(): InventorySessionContextValue {
  const ctx = useContext(Ctx);
  if (!ctx) {
    throw new Error(
      "useInventorySession must be used inside <InventorySessionProvider>",
    );
  }
  return ctx;
}

// Convenience: read the current session_id outside the React tree (e.g. inside
// a non-component helper). Returns null if no open session. Reads from
// sessionStorage directly so it does not require a render.
export function readOpenSessionId(): string | null {
  return readPersisted()?.session_id ?? null;
}
