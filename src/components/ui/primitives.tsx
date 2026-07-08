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
  | "brand"
  | "gold"
  | "success"
  | "warn"
  | "danger"
  | "muted";

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
