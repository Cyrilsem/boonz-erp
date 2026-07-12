// PRD-087 P5 — shared UI primitives on the design tokens (globals.css).
// Use these for new/updated surfaces instead of ad-hoc inline styles.

import type { CSSProperties, ReactNode } from "react";

const font = "'Plus Jakarta Sans', sans-serif";

export function Card({
  children,
  style,
}: {
  children: ReactNode;
  style?: CSSProperties;
}) {
  return (
    <div
      style={{
        background: "var(--surface)",
        border: "1px solid var(--line)",
        borderRadius: 10,
        padding: "16px 18px",
        ...style,
      }}
    >
      {children}
    </div>
  );
}

export function StatCard({
  label,
  value,
  sub,
  accent = "var(--brand)",
  valueColor = "var(--ink)",
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  accent?: string;
  valueColor?: string;
}) {
  return (
    <div
      style={{
        background: "var(--surface)",
        border: "1px solid var(--line)",
        borderTop: `3px solid ${accent}`,
        borderRadius: 10,
        padding: "14px 16px",
        fontFamily: font,
      }}
    >
      <div
        style={{
          fontSize: 10,
          fontWeight: 700,
          letterSpacing: "0.1em",
          textTransform: "uppercase",
          color: "var(--muted)",
        }}
      >
        {label}
      </div>
      <div
        style={{
          fontSize: 26,
          fontWeight: 800,
          color: valueColor,
          letterSpacing: "-0.02em",
          margin: "2px 0",
        }}
      >
        {value}
      </div>
      {sub && (
        <div style={{ fontSize: 11, color: "var(--muted-2)" }}>{sub}</div>
      )}
    </div>
  );
}

export type BadgeTone =
  "brand" | "gold" | "success" | "warn" | "danger" | "muted";

const badgeTones: Record<BadgeTone, { bg: string; fg: string }> = {
  brand: { bg: "var(--brand-tint)", fg: "var(--brand)" },
  gold: { bg: "var(--gold-tint)", fg: "var(--warn)" },
  success: { bg: "var(--success-bg)", fg: "var(--success)" },
  warn: { bg: "var(--warn-bg)", fg: "var(--warn)" },
  danger: { bg: "var(--danger-bg)", fg: "var(--danger)" },
  muted: { bg: "var(--surface-2)", fg: "var(--muted)" },
};

export function Badge({
  children,
  tone = "muted",
}: {
  children: ReactNode;
  tone?: BadgeTone;
}) {
  const t = badgeTones[tone];
  return (
    <span
      style={{
        background: t.bg,
        color: t.fg,
        fontWeight: 700,
        borderRadius: 4,
        padding: "1px 6px",
        fontSize: 10,
        fontFamily: font,
        whiteSpace: "nowrap",
      }}
    >
      {children}
    </span>
  );
}

/**
 * PRD-087 R7 — canonical page chrome. Every module page should render:
 *   <div className="p-8 max-w-7xl">
 *     <PageHeader title="…" subtitle="…" actions={…} />
 *     …content…
 *   </div>
 * matching the Dashboard/Pods/Products pattern (Plus Jakarta 800/28px).
 */
export function PageHeader({
  title,
  subtitle,
  actions,
}: {
  title: string;
  subtitle?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="flex items-center justify-between mb-8 gap-4 flex-wrap">
      <div>
        <h1
          style={{
            fontFamily: font,
            fontWeight: 800,
            fontSize: 28,
            letterSpacing: "-0.02em",
            color: "var(--ink)",
            margin: 0,
          }}
        >
          {title}
        </h1>
        {subtitle && (
          <p style={{ color: "var(--muted)", fontSize: 14, marginTop: 4 }}>
            {subtitle}
          </p>
        )}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  );
}

export function TabBar<T extends string>({
  tabs,
  active,
  onChange,
}: {
  tabs: readonly T[];
  active: T;
  onChange: (t: T) => void;
}) {
  return (
    <div
      style={{
        display: "flex",
        gap: 2,
        borderBottom: "1px solid var(--line)",
        marginBottom: 20,
        overflowX: "auto",
      }}
    >
      {tabs.map((t) => (
        <button
          key={t}
          onClick={() => onChange(t)}
          style={{
            padding: "12px 16px",
            fontSize: 12,
            fontWeight: active === t ? 700 : 500,
            letterSpacing: "0.06em",
            textTransform: "uppercase",
            color: active === t ? "var(--ink)" : "var(--muted)",
            borderBottom:
              active === t ? "3px solid var(--ink)" : "3px solid transparent",
            background: "none",
            border: "none",
            borderBottomWidth: 3,
            borderBottomStyle: "solid",
            borderBottomColor: active === t ? "var(--ink)" : "transparent",
            cursor: "pointer",
            whiteSpace: "nowrap",
            fontFamily: font,
            transition: "all 0.2s",
          }}
        >
          {t}
        </button>
      ))}
    </div>
  );
}

export function SectionHeading({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        fontSize: 10,
        letterSpacing: "0.12em",
        textTransform: "uppercase",
        color: "var(--muted)",
        margin: "18px 0 12px",
        display: "flex",
        alignItems: "center",
        gap: 10,
        fontFamily: font,
        fontWeight: 700,
      }}
    >
      {children}
      <span style={{ flex: 1, height: 1, background: "var(--line)" }} />
    </div>
  );
}
