"use client";

// PRD-140 Item 3: Settings > Users. Gated directly with a v_my_access read
// (Item 4's useRequireArea hook does not exist yet in this loop); redirects
// anyone without app.settings.users to /app.

import { useEffect, useState, useCallback, useMemo } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import {
  adminUsers,
  generateTempPassword,
  AdminUsersError,
  type AdminUserRow,
  type SettableRole,
} from "@/lib/admin-users";

// ─── Static config ─────────────────────────────────────────────────────────

const ROLE_OPTIONS: { value: SettableRole; label: string }[] = [
  { value: "superadmin", label: "Superadmin" },
  { value: "operator_admin", label: "Operator Admin" },
  { value: "manager", label: "Manager" },
  { value: "warehouse", label: "Warehouse" },
  { value: "field_staff", label: "Field Staff" },
  { value: "finance", label: "Finance" },
];

const ROLE_LABEL: Record<string, string> = Object.fromEntries(
  ROLE_OPTIONS.map((r) => [r.value, r.label]),
);

interface AccessArea {
  key: string;
  surface: "app" | "field";
  label: string;
  sort: number;
}
interface Override {
  area_key: string;
  effect: "allow" | "deny";
}
interface AuditRow {
  id: number;
  at: string;
  actor_id: string | null;
  target_user_id: string | null;
  action: string;
  before: unknown;
  after: unknown;
}

type OverrideChoice = "default" | "allow" | "deny";

// ─── Helpers ────────────────────────────────────────────────────────────────

function relativeTime(iso: string | null): string {
  if (!iso) return "Never";
  const ms = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(ms / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo ago`;
  return `${Math.floor(months / 12)}y ago`;
}

function dubaiTime(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleString("en-AE", {
    timeZone: "Asia/Dubai",
    day: "numeric",
    month: "short",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function statusOf(u: AdminUserRow): "Active" | "Disabled" | "Never logged in" {
  if (u.banned_until && new Date(u.banned_until).getTime() > Date.now()) {
    return "Disabled";
  }
  if (!u.last_sign_in_at) return "Never logged in";
  return "Active";
}

function statusColor(status: string): string {
  if (status === "Active") return "#15803d";
  if (status === "Disabled") return "#dc2626";
  return "#6b6860";
}

// ─── Page ───────────────────────────────────────────────────────────────────

export default function SettingsUsersPage() {
  const router = useRouter();

  const [gateChecked, setGateChecked] = useState(false);
  const [allowed, setAllowed] = useState(false);
  const [callerId, setCallerId] = useState<string | null>(null);
  const [callerIsSuperadmin, setCallerIsSuperadmin] = useState(false);

  const [tab, setTab] = useState<"users" | "audit">("users");

  const [users, setUsers] = useState<AdminUserRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [search, setSearch] = useState("");

  const [createOpen, setCreateOpen] = useState(false);
  const [editingUser, setEditingUser] = useState<AdminUserRow | null>(null);

  const [auditRows, setAuditRows] = useState<AuditRow[]>([]);
  const [auditLoading, setAuditLoading] = useState(false);

  // ── Gate ──────────────────────────────────────────────────────────────────
  useEffect(() => {
    (async () => {
      const supabase = createClient();
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (!user) {
        router.replace("/login");
        return;
      }
      setCallerId(user.id);

      const { data: profile } = await supabase
        .from("user_profiles")
        .select("role")
        .eq("id", user.id)
        .single();
      setCallerIsSuperadmin(profile?.role === "superadmin");

      const { data: access } = await supabase
        .from("v_my_access")
        .select("area_key");
      const hasAccess = (access ?? []).some(
        (a: { area_key: string }) => a.area_key === "app.settings.users",
      );
      setAllowed(hasAccess);
      setGateChecked(true);
      if (!hasAccess) router.replace("/app");
    })();
  }, [router]);

  const loadUsers = useCallback(async () => {
    setLoading(true);
    setLoadError(null);
    try {
      const { users } = await adminUsers.list();
      setUsers(users);
    } catch (err) {
      setLoadError(
        err instanceof AdminUsersError ? err.message : "Failed to load users",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (allowed) loadUsers();
  }, [allowed, loadUsers]);

  const loadAudit = useCallback(async () => {
    setAuditLoading(true);
    const supabase = createClient();
    const { data } = await supabase
      .from("access_audit_log")
      .select("id, at, actor_id, target_user_id, action, before, after")
      .order("at", { ascending: false })
      .limit(200);
    setAuditRows(data ?? []);
    setAuditLoading(false);
  }, []);

  useEffect(() => {
    if (allowed && tab === "audit") loadAudit();
  }, [allowed, tab, loadAudit]);

  const filteredSortedUsers = useMemo(() => {
    const q = search.trim().toLowerCase();
    const filtered = q
      ? users.filter(
          (u) =>
            (u.full_name ?? "").toLowerCase().includes(q) ||
            (u.email ?? "").toLowerCase().includes(q),
        )
      : users;
    return [...filtered].sort((a, b) =>
      (a.full_name ?? "").localeCompare(b.full_name ?? ""),
    );
  }, [users, search]);

  if (!gateChecked) {
    return <div style={{ padding: 32, color: "#6b6860" }}>Loading...</div>;
  }
  if (!allowed) {
    return null; // already redirecting
  }

  return (
    <div style={{ padding: 32, maxWidth: 1100 }}>
      <div style={{ marginBottom: 24 }}>
        <h1
          style={{
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "#0a0a0a",
            margin: 0,
          }}
        >
          Users
        </h1>
        <p style={{ color: "#6b6860", fontSize: 14, marginTop: 4 }}>Settings</p>
      </div>

      {/* Tabs */}
      <div
        style={{
          display: "flex",
          gap: 4,
          marginBottom: 20,
          borderBottom: "1px solid #e8e4de",
        }}
      >
        {(["users", "audit"] as const).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            style={{
              padding: "10px 16px",
              fontSize: 13,
              fontWeight: 600,
              color: tab === t ? "#24544a" : "#6b6860",
              borderBottom:
                tab === t ? "2px solid #24544a" : "2px solid transparent",
              background: "none",
              border: "none",
              borderBottomWidth: 2,
              cursor: "pointer",
            }}
          >
            {t === "users" ? "Users" : "Audit"}
          </button>
        ))}
      </div>

      {tab === "users" && (
        <>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              marginBottom: 16,
              gap: 12,
            }}
          >
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search name or email"
              style={{
                flex: 1,
                maxWidth: 320,
                padding: "8px 12px",
                borderRadius: 8,
                border: "1px solid #e8e4de",
                fontSize: 13,
              }}
            />
            <button
              onClick={() => setCreateOpen(true)}
              style={{
                padding: "8px 16px",
                borderRadius: 8,
                border: "none",
                background: "#24544a",
                color: "white",
                fontSize: 13,
                fontWeight: 600,
                cursor: "pointer",
              }}
            >
              + Create user
            </button>
          </div>

          {loadError && (
            <div
              style={{
                padding: 12,
                marginBottom: 12,
                borderRadius: 8,
                background: "#fef2f2",
                border: "1px solid #fecaca",
                color: "#991b1b",
                fontSize: 13,
              }}
            >
              {loadError}
            </div>
          )}

          <div
            style={{
              background: "white",
              border: "1px solid #e8e4de",
              borderRadius: 12,
              overflow: "hidden",
            }}
          >
            <table style={{ width: "100%", borderCollapse: "collapse" }}>
              <thead>
                <tr style={{ background: "#faf9f7" }}>
                  {[
                    "Name",
                    "Email",
                    "Role",
                    "Surfaces",
                    "Last sign-in",
                    "Status",
                    "Sessions",
                    "",
                  ].map((h) => (
                    <th
                      key={h}
                      style={{
                        textAlign: "left",
                        padding: "10px 14px",
                        fontSize: 10,
                        fontWeight: 600,
                        letterSpacing: "0.06em",
                        textTransform: "uppercase",
                        color: "#6b6860",
                        borderBottom: "1px solid #e8e4de",
                      }}
                    >
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {loading ? (
                  <tr>
                    <td
                      colSpan={8}
                      style={{
                        padding: 24,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      Loading...
                    </td>
                  </tr>
                ) : filteredSortedUsers.length === 0 ? (
                  <tr>
                    <td
                      colSpan={8}
                      style={{
                        padding: 24,
                        textAlign: "center",
                        color: "#6b6860",
                      }}
                    >
                      No users found.
                    </td>
                  </tr>
                ) : (
                  filteredSortedUsers.map((u) => {
                    const status = statusOf(u);
                    return (
                      <tr
                        key={u.id}
                        style={{ borderBottom: "1px solid #f3f1ed" }}
                      >
                        <td
                          style={{
                            padding: "10px 14px",
                            fontSize: 13,
                            fontWeight: 500,
                          }}
                        >
                          {u.full_name ?? "-"}
                        </td>
                        <td
                          style={{
                            padding: "10px 14px",
                            fontSize: 13,
                            color: "#6b6860",
                          }}
                        >
                          {u.email ?? "-"}
                        </td>
                        <td style={{ padding: "10px 14px", fontSize: 13 }}>
                          {ROLE_LABEL[u.role] ?? u.role}
                        </td>
                        <td style={{ padding: "10px 14px", fontSize: 11 }}>
                          <SurfaceChips surfaces={u.surfaces} />
                        </td>
                        <td
                          style={{
                            padding: "10px 14px",
                            fontSize: 13,
                            color: "#6b6860",
                          }}
                        >
                          {relativeTime(u.last_sign_in_at)}
                        </td>
                        <td
                          style={{
                            padding: "10px 14px",
                            fontSize: 13,
                            fontWeight: 600,
                            color: statusColor(status),
                          }}
                        >
                          {status}
                        </td>
                        <td style={{ padding: "10px 14px", fontSize: 13 }}>
                          {u.open_sessions}
                        </td>
                        <td
                          style={{ padding: "10px 14px", textAlign: "right" }}
                        >
                          <button
                            onClick={() => setEditingUser(u)}
                            style={{
                              padding: "5px 12px",
                              fontSize: 12,
                              fontWeight: 600,
                              color: "#24544a",
                              background: "#eef5f2",
                              border: "none",
                              borderRadius: 6,
                              cursor: "pointer",
                            }}
                          >
                            Edit
                          </button>
                        </td>
                      </tr>
                    );
                  })
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {tab === "audit" && (
        <div
          style={{
            background: "white",
            border: "1px solid #e8e4de",
            borderRadius: 12,
            overflow: "hidden",
          }}
        >
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ background: "#faf9f7" }}>
                {["When (Dubai)", "Actor", "Target", "Action", "Detail"].map(
                  (h) => (
                    <th
                      key={h}
                      style={{
                        textAlign: "left",
                        padding: "10px 14px",
                        fontSize: 10,
                        fontWeight: 600,
                        letterSpacing: "0.06em",
                        textTransform: "uppercase",
                        color: "#6b6860",
                        borderBottom: "1px solid #e8e4de",
                      }}
                    >
                      {h}
                    </th>
                  ),
                )}
              </tr>
            </thead>
            <tbody>
              {auditLoading ? (
                <tr>
                  <td
                    colSpan={5}
                    style={{
                      padding: 24,
                      textAlign: "center",
                      color: "#6b6860",
                    }}
                  >
                    Loading...
                  </td>
                </tr>
              ) : auditRows.length === 0 ? (
                <tr>
                  <td
                    colSpan={5}
                    style={{
                      padding: 24,
                      textAlign: "center",
                      color: "#6b6860",
                    }}
                  >
                    No audit rows yet.
                  </td>
                </tr>
              ) : (
                auditRows.map((r) => (
                  <tr key={r.id} style={{ borderBottom: "1px solid #f3f1ed" }}>
                    <td
                      style={{
                        padding: "8px 14px",
                        fontSize: 12,
                        color: "#6b6860",
                      }}
                    >
                      {dubaiTime(r.at)}
                    </td>
                    <td
                      style={{
                        padding: "8px 14px",
                        fontSize: 11,
                        fontFamily: "monospace",
                      }}
                    >
                      {r.actor_id?.slice(0, 8) ?? "-"}
                    </td>
                    <td
                      style={{
                        padding: "8px 14px",
                        fontSize: 11,
                        fontFamily: "monospace",
                      }}
                    >
                      {r.target_user_id?.slice(0, 8) ?? "-"}
                    </td>
                    <td
                      style={{
                        padding: "8px 14px",
                        fontSize: 12,
                        fontWeight: 600,
                      }}
                    >
                      {r.action}
                    </td>
                    <td
                      style={{
                        padding: "8px 14px",
                        fontSize: 11,
                        color: "#6b6860",
                      }}
                    >
                      {JSON.stringify(r.after ?? r.before ?? {})}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {createOpen && (
        <CreateUserDialog
          onClose={() => setCreateOpen(false)}
          onCreated={() => {
            setCreateOpen(false);
            loadUsers();
          }}
        />
      )}

      {editingUser && callerId && (
        <EditUserDrawer
          user={editingUser}
          callerId={callerId}
          callerIsSuperadmin={callerIsSuperadmin}
          onClose={() => setEditingUser(null)}
          onSaved={() => {
            setEditingUser(null);
            loadUsers();
          }}
        />
      )}
    </div>
  );
}

// ─── Surface chips ──────────────────────────────────────────────────────────

function SurfaceChips({
  surfaces,
}: {
  surfaces: { app: boolean; field: boolean; tracker: boolean };
}) {
  const chip = (label: string, on: boolean) => (
    <span
      key={label}
      style={{
        display: "inline-block",
        marginRight: 4,
        padding: "2px 7px",
        borderRadius: 999,
        fontSize: 10,
        fontWeight: 700,
        background: on ? "#e6f0ec" : "#f3f1ed",
        color: on ? "#15803d" : "#b5afa3",
      }}
    >
      {label}
    </span>
  );
  return (
    <>
      {chip("App", surfaces.app)}
      {chip("Field", surfaces.field)}
      {chip("Tracker", surfaces.tracker)}
    </>
  );
}

// ─── Create dialog ──────────────────────────────────────────────────────────

function CreateUserDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: () => void;
}) {
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<SettableRole>("field_staff");
  const [password, setPassword] = useState(generateTempPassword());
  const [copied, setCopied] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState(false);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      await adminUsers.create({
        email: email.trim(),
        full_name: fullName.trim(),
        role,
        password,
      });
      setCreated(true);
    } catch (err) {
      setError(err instanceof AdminUsersError ? err.message : "Create failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal onClose={onClose} title="Create user">
      {created ? (
        <div>
          <p
            style={{
              fontSize: 13,
              color: "#15803d",
              fontWeight: 600,
              marginBottom: 12,
            }}
          >
            User created.
          </p>
          <p style={{ fontSize: 12, color: "#6b6860", marginBottom: 6 }}>
            Temporary password (shown once):
          </p>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 8,
              padding: "8px 12px",
              borderRadius: 8,
              background: "#faf9f7",
              border: "1px solid #e8e4de",
              fontFamily: "monospace",
              fontSize: 14,
              marginBottom: 16,
            }}
          >
            <span style={{ flex: 1 }}>{password}</span>
            <button
              onClick={() => {
                navigator.clipboard.writeText(password);
                setCopied(true);
              }}
              style={{
                fontSize: 11,
                fontWeight: 600,
                color: "#24544a",
                background: "none",
                border: "none",
                cursor: "pointer",
              }}
            >
              {copied ? "Copied" : "Copy"}
            </button>
          </div>
          <button
            onClick={onCreated}
            style={{
              padding: "8px 16px",
              borderRadius: 8,
              border: "none",
              background: "#24544a",
              color: "white",
              fontSize: 13,
              fontWeight: 600,
              cursor: "pointer",
            }}
          >
            Done
          </button>
        </div>
      ) : (
        <div>
          <LabeledInput
            label="Full name"
            value={fullName}
            onChange={setFullName}
          />
          <LabeledInput
            label="Email"
            value={email}
            onChange={setEmail}
            type="email"
          />
          <div style={{ marginBottom: 14 }}>
            <FieldLabel>Role</FieldLabel>
            <select
              value={role}
              onChange={(e) => setRole(e.target.value as SettableRole)}
              style={selectStyle}
            >
              {ROLE_OPTIONS.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
          </div>
          <div style={{ marginBottom: 14 }}>
            <FieldLabel>Temporary password</FieldLabel>
            <div style={{ display: "flex", gap: 8 }}>
              <input
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                style={{ ...inputStyle, fontFamily: "monospace" }}
              />
              <button
                onClick={() => setPassword(generateTempPassword())}
                style={{
                  padding: "0 12px",
                  fontSize: 12,
                  fontWeight: 600,
                  color: "#24544a",
                  background: "#eef5f2",
                  border: "none",
                  borderRadius: 8,
                  cursor: "pointer",
                }}
              >
                Regenerate
              </button>
            </div>
          </div>
          {error && (
            <p style={{ fontSize: 12, color: "#991b1b", marginBottom: 12 }}>
              {error}
            </p>
          )}
          <button
            onClick={submit}
            disabled={busy || !fullName.trim() || !email.trim()}
            style={{
              padding: "8px 16px",
              borderRadius: 8,
              border: "none",
              background: busy ? "#9ca89f" : "#24544a",
              color: "white",
              fontSize: 13,
              fontWeight: 600,
              cursor: busy ? "default" : "pointer",
            }}
          >
            {busy ? "Creating..." : "Create"}
          </button>
        </div>
      )}
    </Modal>
  );
}

// ─── Edit drawer ────────────────────────────────────────────────────────────

function EditUserDrawer({
  user,
  callerId,
  callerIsSuperadmin,
  onClose,
  onSaved,
}: {
  user: AdminUserRow;
  callerId: string;
  callerIsSuperadmin: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const isSelf = user.id === callerId;
  const targetIsSuperadmin = user.role === "superadmin";
  // Role-change guard: disabled on self (always) or on a superadmin target
  // when the caller is not a superadmin.
  const roleLocked = isSelf || (targetIsSuperadmin && !callerIsSuperadmin);
  // Ban guard: disabled on self (always) or on a superadmin target when the
  // caller is not a superadmin.
  const banLocked = isSelf || (targetIsSuperadmin && !callerIsSuperadmin);

  const [fullName, setFullName] = useState(user.full_name ?? "");
  const [role, setRole] = useState<SettableRole>(user.role);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [areas, setAreas] = useState<AccessArea[]>([]);
  const [roleDefaultKeys, setRoleDefaultKeys] = useState<Set<string>>(
    new Set(),
  );
  const [overrides, setOverrides] = useState<Map<string, "allow" | "deny">>(
    new Map(),
  );
  const [pending, setPending] = useState<Map<string, OverrideChoice>>(
    new Map(),
  );
  const [matrixLoading, setMatrixLoading] = useState(true);

  useEffect(() => {
    (async () => {
      setMatrixLoading(true);
      const supabase = createClient();
      const [
        { data: areaRows },
        { data: defaultRows },
        { data: overrideRows },
      ] = await Promise.all([
        supabase
          .from("access_areas")
          .select("key, surface, label, sort")
          .order("sort"),
        supabase
          .from("role_area_defaults")
          .select("area_key")
          .eq("role", user.role),
        supabase
          .from("user_area_overrides")
          .select("area_key, effect")
          .eq("user_id", user.id),
      ]);
      setAreas((areaRows ?? []) as AccessArea[]);
      setRoleDefaultKeys(
        new Set(
          (defaultRows ?? []).map((d: { area_key: string }) => d.area_key),
        ),
      );
      const ov = new Map<string, "allow" | "deny">();
      for (const o of (overrideRows ?? []) as Override[]) {
        ov.set(o.area_key, o.effect);
      }
      setOverrides(ov);
      setMatrixLoading(false);
    })();
  }, [user.id, user.role]);

  function choiceFor(key: string): OverrideChoice {
    if (pending.has(key)) return pending.get(key)!;
    const ov = overrides.get(key);
    if (ov === "allow") return "allow";
    if (ov === "deny") return "deny";
    return "default";
  }

  function effectiveFor(key: string): boolean {
    const choice = choiceFor(key);
    if (choice === "allow") return true;
    if (choice === "deny") return false;
    return roleDefaultKeys.has(key);
  }

  function setChoice(key: string, choice: OverrideChoice) {
    setPending((prev) => {
      const next = new Map(prev);
      next.set(key, choice);
      return next;
    });
  }

  async function saveAll() {
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      if (fullName.trim() && fullName.trim() !== user.full_name) {
        await adminUsers.setName(user.id, fullName.trim());
      }
      if (!roleLocked && role !== user.role) {
        await adminUsers.setRole(user.id, role);
      }
      for (const [key, choice] of pending.entries()) {
        const current = overrides.get(key) ?? null;
        if (choice === "default" && current !== null) {
          await adminUsers.clearOverride(user.id, key);
        } else if (choice === "allow" && current !== "allow") {
          await adminUsers.setOverride(user.id, key, "allow");
        } else if (choice === "deny" && current !== "deny") {
          await adminUsers.setOverride(user.id, key, "deny");
        }
      }
      setMessage("Saved.");
      onSaved();
    } catch (err) {
      setError(err instanceof AdminUsersError ? err.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  async function runAction(fn: () => Promise<unknown>, successMsg: string) {
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      await fn();
      setMessage(successMsg);
    } catch (err) {
      setError(err instanceof AdminUsersError ? err.message : "Action failed");
    } finally {
      setBusy(false);
    }
  }

  const status = statusOf(user);
  const appAreas = areas.filter((a) => a.surface === "app");
  const fieldAreas = areas.filter((a) => a.surface === "field");

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(10,10,10,0.3)",
        display: "flex",
        justifyContent: "flex-end",
        zIndex: 50,
      }}
      onClick={onClose}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 480,
          maxWidth: "100%",
          background: "white",
          height: "100%",
          overflowY: "auto",
          padding: 28,
        }}
      >
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            marginBottom: 20,
          }}
        >
          <h2 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>
            {user.full_name ?? user.email}
          </h2>
          <button
            onClick={onClose}
            style={{
              border: "none",
              background: "none",
              fontSize: 18,
              cursor: "pointer",
            }}
          >
            x
          </button>
        </div>

        <p style={{ fontSize: 12, color: "#6b6860", marginBottom: 20 }}>
          {user.email} - {status}
        </p>

        <LabeledInput
          label="Full name"
          value={fullName}
          onChange={setFullName}
        />

        <div style={{ marginBottom: 14 }}>
          <FieldLabel>Role</FieldLabel>
          <select
            value={role}
            onChange={(e) => setRole(e.target.value as SettableRole)}
            disabled={roleLocked}
            title={
              roleLocked
                ? isSelf
                  ? "You cannot change your own role"
                  : "Only a superadmin can change a superadmin's role"
                : undefined
            }
            style={{ ...selectStyle, opacity: roleLocked ? 0.5 : 1 }}
          >
            {ROLE_OPTIONS.map((r) => (
              <option key={r.value} value={r.value}>
                {r.label}
              </option>
            ))}
          </select>
        </div>

        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 8,
            marginBottom: 20,
          }}
        >
          <ActionButton
            label="Send password reset"
            onClick={() =>
              runAction(async () => {
                const r = await adminUsers.sendReset(user.id);
                setMessage(`Reset link: ${r.recovery_link}`);
              }, "")
            }
            busy={busy}
          />
          <ActionButton
            label="Set temporary password"
            onClick={() =>
              runAction(
                () => adminUsers.setPassword(user.id, generateTempPassword()),
                "Password set. Ask the user to change it on next login.",
              )
            }
            busy={busy}
          />
          <ActionButton
            label="Sign out everywhere"
            onClick={() =>
              runAction(
                () => adminUsers.revokeSessions(user.id),
                "Sessions revoked.",
              )
            }
            busy={busy}
          />
          <ActionButton
            label={status === "Disabled" ? "Enable" : "Disable"}
            onClick={() =>
              runAction(
                () =>
                  status === "Disabled"
                    ? adminUsers.unban(user.id)
                    : adminUsers.ban(user.id),
                status === "Disabled" ? "Enabled." : "Disabled.",
              )
            }
            busy={busy || banLocked}
            disabled={banLocked}
            title={
              banLocked
                ? isSelf
                  ? "You cannot disable yourself"
                  : "Only a superadmin can disable a superadmin"
                : undefined
            }
          />
        </div>

        {message && (
          <div
            style={{
              padding: 10,
              marginBottom: 14,
              borderRadius: 8,
              background: "#eef5f2",
              color: "#15803d",
              fontSize: 12,
              wordBreak: "break-all",
            }}
          >
            {message}
          </div>
        )}
        {error && (
          <div
            style={{
              padding: 10,
              marginBottom: 14,
              borderRadius: 8,
              background: "#fef2f2",
              color: "#991b1b",
              fontSize: 12,
            }}
          >
            {error}
          </div>
        )}

        <FieldLabel>Area access</FieldLabel>
        {matrixLoading ? (
          <p style={{ fontSize: 12, color: "#6b6860" }}>Loading...</p>
        ) : (
          <div style={{ marginTop: 8 }}>
            <AreaGroup
              title="App"
              areaList={appAreas}
              choiceFor={choiceFor}
              effectiveFor={effectiveFor}
              setChoice={setChoice}
            />
            <AreaGroup
              title="Field"
              areaList={fieldAreas}
              choiceFor={choiceFor}
              effectiveFor={effectiveFor}
              setChoice={setChoice}
            />
          </div>
        )}

        <button
          onClick={saveAll}
          disabled={busy}
          style={{
            marginTop: 20,
            padding: "10px 20px",
            borderRadius: 8,
            border: "none",
            background: busy ? "#9ca89f" : "#24544a",
            color: "white",
            fontSize: 13,
            fontWeight: 600,
            cursor: busy ? "default" : "pointer",
            width: "100%",
          }}
        >
          {busy ? "Saving..." : "Save"}
        </button>
      </div>
    </div>
  );
}

function AreaGroup({
  title,
  areaList,
  choiceFor,
  effectiveFor,
  setChoice,
}: {
  title: string;
  areaList: AccessArea[];
  choiceFor: (key: string) => OverrideChoice;
  effectiveFor: (key: string) => boolean;
  setChoice: (key: string, choice: OverrideChoice) => void;
}) {
  return (
    <div style={{ marginBottom: 16 }}>
      <p
        style={{
          fontSize: 10,
          fontWeight: 600,
          letterSpacing: "0.08em",
          textTransform: "uppercase",
          color: "#6b6860",
          marginBottom: 8,
        }}
      >
        {title}
      </p>
      {areaList.map((a) => {
        const choice = choiceFor(a.key);
        const effective = effectiveFor(a.key);
        return (
          <div
            key={a.key}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "6px 0",
              borderBottom: "1px solid #f3f1ed",
            }}
          >
            <span
              style={{
                fontSize: 12,
                color: effective ? "#0a0a0a" : "#b5afa3",
                fontWeight: effective ? 500 : 400,
              }}
            >
              {a.label}
            </span>
            <select
              value={choice}
              onChange={(e) =>
                setChoice(a.key, e.target.value as OverrideChoice)
              }
              style={{
                fontSize: 11,
                padding: "3px 6px",
                borderRadius: 6,
                border: "1px solid #e8e4de",
                background: effective ? "#eef5f2" : "#f3f1ed",
                color: effective ? "#15803d" : "#6b6860",
              }}
            >
              <option value="default">Default</option>
              <option value="allow">Allow</option>
              <option value="deny">Deny</option>
            </select>
          </div>
        );
      })}
    </div>
  );
}

function ActionButton({
  label,
  onClick,
  busy,
  disabled,
  title,
}: {
  label: string;
  onClick: () => void;
  busy?: boolean;
  disabled?: boolean;
  title?: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={busy || disabled}
      title={title}
      style={{
        padding: "6px 12px",
        fontSize: 12,
        fontWeight: 600,
        color: disabled ? "#b5afa3" : "#24544a",
        background: disabled ? "#f3f1ed" : "#eef5f2",
        border: "none",
        borderRadius: 6,
        cursor: disabled || busy ? "default" : "pointer",
      }}
    >
      {label}
    </button>
  );
}

// ─── Shared small components ───────────────────────────────────────────────

function Modal({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: React.ReactNode;
}) {
  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(10,10,10,0.3)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        zIndex: 50,
      }}
      onClick={onClose}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          width: 420,
          maxWidth: "90%",
          background: "white",
          borderRadius: 12,
          padding: 24,
        }}
      >
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "center",
            marginBottom: 16,
          }}
        >
          <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>{title}</h2>
          <button
            onClick={onClose}
            style={{
              border: "none",
              background: "none",
              fontSize: 18,
              cursor: "pointer",
            }}
          >
            x
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <div
      style={{
        fontSize: 10,
        fontWeight: 600,
        letterSpacing: "0.08em",
        textTransform: "uppercase",
        color: "#6b6860",
        marginBottom: 5,
      }}
    >
      {children}
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  flex: 1,
  padding: "8px 12px",
  borderRadius: 8,
  border: "1px solid #e8e4de",
  fontSize: 13,
  width: "100%",
};

const selectStyle: React.CSSProperties = {
  padding: "8px 12px",
  borderRadius: 8,
  border: "1px solid #e8e4de",
  fontSize: 13,
  width: "100%",
};

function LabeledInput({
  label,
  value,
  onChange,
  type = "text",
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  type?: string;
}) {
  return (
    <div style={{ marginBottom: 14 }}>
      <FieldLabel>{label}</FieldLabel>
      <input
        type={type}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        style={inputStyle}
      />
    </div>
  );
}
