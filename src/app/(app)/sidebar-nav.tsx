"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";

// PRD-087 P2 — grouped navigation.
// 16 flat items → 4 titled sections + dashboard. Previously-orphaned pages
// (Pods, Drift Monitor, Feedback Inbox, Inventory Sessions, WH Quarantine)
// are now surfaced. Role gating preserved from the flat nav; the ghost
// "Pods" entry in the old hiddenByRole.finance now points at a real item.

interface NavItem {
  label: string;
  href: string;
  icon: string;
  ownerOnly?: boolean;
}

interface NavSection {
  title: string | null;
  items: NavItem[];
}

const sections: NavSection[] = [
  {
    title: null,
    items: [{ label: "Dashboard", href: "/app", icon: "▦" }],
  },
  {
    title: "Operations",
    items: [
      { label: "Refill & Dispatch", href: "/refill", icon: "↻" },
      { label: "Driver Adds", href: "/admin/driver-additions", icon: "⚑" },
      { label: "Machines", href: "/app/machines", icon: "▣" },
      { label: "Pods", href: "/app/pods", icon: "⬢" },
      { label: "Inventory", href: "/app/inventory", icon: "▤" },
    ],
  },
  {
    title: "Supply",
    items: [
      { label: "Products", href: "/app/products", icon: "☐" },
      { label: "Suppliers", href: "/app/suppliers", icon: "⇠" },
      { label: "Procurement", href: "/app/procurement", icon: "⛁" },
      { label: "Lifecycle", href: "/app/lifecycle", icon: "⬡" },
    ],
  },
  {
    title: "Commercial",
    items: [
      { label: "Performance", href: "/app/performance", icon: "◆" },
      { label: "Financials", href: "/app/financials", icon: "$" },
      { label: "Consumers", href: "/refill/consumers", icon: "⇢" },
      { label: "Sales Pipeline", href: "/app/sales-pipeline", icon: "◎" },
    ],
  },
  {
    title: "Admin",
    items: [
      { label: "SIM Cards", href: "/app/sims", icon: "◈" },
      { label: "Feedback Inbox", href: "/admin/feedback-inbox", icon: "✉" },
      {
        label: "Inventory Sessions",
        href: "/admin/inventory-sessions",
        icon: "≡",
      },
      { label: "WH Quarantine", href: "/admin/wh-quarantine", icon: "⊘" },
      { label: "Drift Monitor", href: "/refill/drift", icon: "±" },
      { label: "Tracker", href: "/app/tracker", icon: "✓", ownerOnly: true },
      { label: "Settings", href: "/app/settings", icon: "⚙" },
    ],
  },
];

// Role gating — carried over from the flat nav, extended to the newly
// surfaced items (ops-admin tools hidden from finance/warehouse).
const hiddenByRole: Record<string, string[]> = {
  finance: [
    "Pods",
    "Refill & Dispatch",
    "Driver Adds",
    "Consumers",
    "Lifecycle",
    "Sales Pipeline",
    "Feedback Inbox",
    "Inventory Sessions",
    "WH Quarantine",
    "Drift Monitor",
  ],
  manager: ["Settings", "Lifecycle"],
  // Warehouse: inventory, products, procurement, machines, refill/dispatch,
  // suppliers. Hide financial, commercial, and admin-only sections.
  warehouse: [
    "Financials",
    "Consumers",
    "Performance",
    "Lifecycle",
    "SIM Cards",
    "Sales Pipeline",
    "Settings",
    "Feedback Inbox",
    "Inventory Sessions",
    "Drift Monitor",
  ],
};

export default function SidebarNav({
  role,
  canSeeTracker,
}: {
  role: string;
  canSeeTracker: boolean;
}) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = useState(false);

  const hidden = hiddenByRole[role] ?? [];
  const visibleSections = sections
    .map((s) => ({
      ...s,
      items: s.items
        .filter((item) => !hidden.includes(item.label))
        // Owner-only items (the Tracker) show for the owner and flagged Boonz
        // collaborators; everyone else is dropped because the page bounces them.
        .filter((item) => !item.ownerOnly || canSeeTracker),
    }))
    .filter((s) => s.items.length > 0);

  const isActive = (href: string) => {
    // Exact match for /app and /refill so children don't double-highlight
    // (e.g. /refill/consumers and /refill/drift are their own entries).
    if (href === "/app") return pathname === "/app";
    if (href === "/refill") return pathname === "/refill";
    return pathname.startsWith(href);
  };

  return (
    <aside
      className={`flex flex-col shrink-0 transition-[width] ${
        collapsed ? "w-14" : "w-56"
      } max-md:w-14`}
      style={{
        background: "var(--brand)",
        borderRight: "1px solid var(--brand-deep)",
      }}
    >
      {/* Logo bar */}
      <div
        className="flex h-14 items-center justify-between px-3"
        style={{ borderBottom: "1px solid rgba(255,255,255,0.08)" }}
      >
        {!collapsed && (
          <span
            className="max-md:hidden"
            style={{
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontWeight: 800,
              fontSize: 16,
              letterSpacing: "-0.02em",
              color: "var(--gold)",
            }}
          >
            Boonz
          </span>
        )}
        <button
          onClick={() => setCollapsed(!collapsed)}
          className="rounded p-1 max-md:hidden transition-colors"
          style={{ color: "rgba(255,255,255,0.5)" }}
          onMouseEnter={(e) =>
            ((e.currentTarget as HTMLButtonElement).style.color = "white")
          }
          onMouseLeave={(e) =>
            ((e.currentTarget as HTMLButtonElement).style.color =
              "rgba(255,255,255,0.5)")
          }
          aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
        >
          {collapsed ? "▸" : "◂"}
        </button>
      </div>

      {/* Nav sections */}
      <nav className="flex-1 overflow-y-auto py-2">
        {visibleSections.map((section, si) => (
          <div key={section.title ?? `s${si}`} className="mb-1">
            {section.title && (
              <div
                className={collapsed ? "mx-3 my-2 max-md:block" : "px-4 pt-3 pb-1 max-md:hidden"}
                style={
                  collapsed
                    ? { borderTop: "1px solid rgba(255,255,255,0.12)" }
                    : {
                        fontSize: 10,
                        fontWeight: 700,
                        letterSpacing: "0.1em",
                        textTransform: "uppercase",
                        color: "rgba(255,255,255,0.38)",
                      }
                }
              >
                {!collapsed && section.title}
              </div>
            )}
            {section.items.map((item) => {
              const active = isActive(item.href);
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  title={item.label}
                  className="flex items-center gap-3 px-3 py-2 mx-1 rounded text-sm transition-colors"
                  style={
                    active
                      ? {
                          background: "var(--ink)",
                          color: "white",
                          fontWeight: 600,
                        }
                      : {
                          color: "rgba(255,255,255,0.7)",
                        }
                  }
                  onMouseEnter={(e) => {
                    if (!active) {
                      (e.currentTarget as HTMLAnchorElement).style.background =
                        "rgba(255,255,255,0.10)";
                      (e.currentTarget as HTMLAnchorElement).style.color =
                        "white";
                    }
                  }}
                  onMouseLeave={(e) => {
                    if (!active) {
                      (e.currentTarget as HTMLAnchorElement).style.background =
                        "transparent";
                      (e.currentTarget as HTMLAnchorElement).style.color =
                        "rgba(255,255,255,0.7)";
                    }
                  }}
                >
                  <span
                    className="w-5 text-center shrink-0"
                    style={active ? { color: "var(--gold)" } : undefined}
                  >
                    {item.icon}
                  </span>
                  <span
                    className={
                      collapsed ? "hidden max-md:hidden" : "max-md:hidden"
                    }
                  >
                    {item.label}
                  </span>
                </Link>
              );
            })}
          </div>
        ))}
      </nav>
    </aside>
  );
}
