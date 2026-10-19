"use client";

// PRD-142b A1 to A3: the Products tab velocity x coverage map, drawn as plain
// SVG (no new dependency) so the plot can own its geometry:
// - every mark, trail, median line and label sits inside one clipPath bound
//   to the plot rectangle, so nothing is ever drawn outside the frame (A1);
// - both domains come from the points of the current scope and position
//   (Trails include the prime points), padded, y kept on a log scale (A2);
// - the hover card is pinned inside the chart bounds and flips left or above
//   near the right or bottom edge; it is absolutely positioned (no layout
//   shift) and lives outside the memoised plot, so hover never re-renders
//   the chart (A3).

import { memo, useEffect, useId, useMemo, useRef, useState } from "react";
import type { ProductRow } from "./ProductsTab";
import {
  aed,
  MATURITY_COLOR,
  num,
  pct,
  PLAYBOOK_COLOR,
  PLAYBOOK_LABEL,
} from "./shared";

type Position = "current" | "prime" | "trails";
type XMode = "coverage" | "facing";

const HEIGHT = 460;
const M = { top: 16, right: 24, bottom: 44, left: 56 };
const CARD_W = 240;
const CARD_H = 150;
const GAP = 12;
const LOG_TICKS = [
  0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000,
];

export function xValue(p: ProductRow, prime: boolean, xMode: XMode) {
  if (xMode === "facing")
    return Math.max(
      0.1,
      ((prime ? p.prime_velocity : p.velocity) ?? 0) * (p.price_per_unit ?? 0),
    );
  return ((prime ? p.prime_coverage : p.coverage) ?? 0) * 100;
}
export function yValue(p: ProductRow, prime: boolean) {
  return Math.max(0.05, (prime ? p.prime_velocity : p.velocity) ?? 0.05);
}

function niceStep(span: number, target = 6) {
  const raw = span / target;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const n = raw / mag;
  return (n >= 5 ? 10 : n >= 2 ? 5 : n >= 1 ? 2 : 1) * mag;
}

interface Pt {
  id: string;
  name: string;
  x: number;
  y: number;
  p: ProductRow;
}

interface Hover {
  p: ProductRow;
  px: number;
  py: number;
}

export default function PortfolioMap({
  products,
  position,
  xMode,
  labelAll,
  medianY,
  medianX,
  onOpen,
}: {
  products: ProductRow[];
  position: Position;
  xMode: XMode;
  labelAll: boolean;
  medianY: number | null;
  medianX: number | null;
  onOpen: (id: string) => void;
}) {
  const wrap = useRef<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(0);
  const [hover, setHover] = useState<Hover | null>(null);

  useEffect(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver((e) =>
      setWidth(Math.round(e[0].contentRect.width)),
    );
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const onOpenRef = useRef(onOpen);
  useEffect(() => {
    onOpenRef.current = onOpen;
  }, [onOpen]);

  return (
    <div
      ref={wrap}
      className="relative"
      style={{ height: HEIGHT }}
      data-testid="strategy-portfolio-map"
    >
      {width > 0 && (
        <Plot
          width={width}
          products={products}
          position={position}
          xMode={xMode}
          labelAll={labelAll}
          medianY={medianY}
          medianX={medianX}
          setHover={setHover}
          onOpenRef={onOpenRef}
        />
      )}
      {hover && <HoverCard hover={hover} width={width} />}
    </div>
  );
}

const Plot = memo(function Plot({
  width,
  products,
  position,
  xMode,
  labelAll,
  medianY,
  medianX,
  setHover,
  onOpenRef,
}: {
  width: number;
  products: ProductRow[];
  position: Position;
  xMode: XMode;
  labelAll: boolean;
  medianY: number | null;
  medianX: number | null;
  setHover: (h: Hover | null) => void;
  onOpenRef: { current: (id: string) => void };
}) {
  const clipId = `pm-clip-${useId().replace(/:/g, "")}`;

  const geo = useMemo(() => {
    const primeMode = position === "prime";
    const points: Pt[] = products
      .filter((p) =>
        primeMode ? p.prime_velocity !== null : p.velocity !== null,
      )
      .map((p) => ({
        id: p.pod_product_id,
        name: p.name,
        x: xValue(p, primeMode, xMode),
        y: yValue(p, primeMode),
        p,
      }));
    const trails =
      position === "trails"
        ? products
            .filter((p) => p.prime_velocity !== null && p.velocity !== null)
            .map((p) => ({
              id: p.pod_product_id,
              color: PLAYBOOK_COLOR[p.playbook],
              x0: xValue(p, true, xMode),
              y0: yValue(p, true),
              x1: xValue(p, false, xMode),
              y1: yValue(p, false),
            }))
        : [];

    // Domain from the points actually drawn in this scope and position.
    const xs = [...points.map((d) => d.x), ...trails.map((t) => t.x0)];
    const ys = [...points.map((d) => d.y), ...trails.map((t) => t.y0)];
    if (medianY !== null) ys.push(medianY);
    if (medianX !== null) xs.push(medianX);
    const yLo = ys.length ? Math.min(...ys) : 0.5;
    const yHi = ys.length ? Math.max(...ys) : 40;
    const yMin = Math.max(0.01, yLo / 1.35);
    const yMax = Math.max(yMin * 4, yHi * 1.35);
    const xHi = xs.length ? Math.max(...xs) : 100;
    const xMax =
      xMode === "coverage"
        ? Math.min(100, Math.max(5, xHi * 1.08 + 1))
        : Math.max(1, xHi * 1.08);
    const xMin = 0;

    const pw = Math.max(10, width - M.left - M.right);
    const ph = HEIGHT - M.top - M.bottom;
    const sx = (v: number) => M.left + ((v - xMin) / (xMax - xMin)) * pw;
    const ly0 = Math.log10(yMin);
    const ly1 = Math.log10(yMax);
    const sy = (v: number) =>
      M.top +
      ph -
      ((Math.log10(Math.max(v, yMin / 10)) - ly0) / (ly1 - ly0)) * ph;

    const step = niceStep(xMax - xMin);
    const xTicks: number[] = [];
    for (let v = xMin; v <= xMax + 1e-9; v += step) xTicks.push(+v.toFixed(6));
    const yTicks = LOG_TICKS.filter((t) => t >= yMin && t <= yMax);

    return {
      points,
      trails,
      xMin,
      xMax,
      yMin,
      yMax,
      pw,
      ph,
      sx,
      sy,
      xTicks,
      yTicks,
    };
  }, [products, position, xMode, medianY, medianX, width]);

  const { points, trails, pw, ph, sx, sy, xTicks, yTicks } = geo;

  return (
    <svg
      width={width}
      height={HEIGHT}
      role="img"
      aria-label="Velocity by coverage map"
      data-domain={`x ${geo.xMin}-${geo.xMax.toFixed(1)} y ${geo.yMin.toFixed(2)}-${geo.yMax.toFixed(1)}`}
      style={{ display: "block", overflow: "hidden" }}
    >
      <defs>
        <clipPath id={clipId}>
          <rect x={M.left} y={M.top} width={pw} height={ph} />
        </clipPath>
      </defs>

      {/* Grid and axes (outside the clip, inside the plot frame). */}
      <g fontSize={11} fill="var(--muted)">
        {xTicks.map((t) => (
          <g key={`x${t}`}>
            <line
              x1={sx(t)}
              x2={sx(t)}
              y1={M.top}
              y2={M.top + ph}
              stroke="var(--line)"
            />
            <text x={sx(t)} y={M.top + ph + 16} textAnchor="middle">
              {xMode === "coverage" ? `${t}%` : num(t, t < 10 ? 1 : 0)}
            </text>
          </g>
        ))}
        {yTicks.map((t) => (
          <g key={`y${t}`}>
            <line
              x1={M.left}
              x2={M.left + pw}
              y1={sy(t)}
              y2={sy(t)}
              stroke="var(--line)"
            />
            <text x={M.left - 6} y={sy(t) + 4} textAnchor="end">
              {t}
            </text>
          </g>
        ))}
        <rect
          x={M.left}
          y={M.top}
          width={pw}
          height={ph}
          fill="none"
          stroke="var(--line)"
        />
        <text x={M.left + pw / 2} y={HEIGHT - 6} textAnchor="middle">
          {xMode === "coverage"
            ? "Coverage (% of selling machines)"
            : "AED per facing per week"}
        </text>
        <text
          transform={`translate(14 ${M.top + ph / 2}) rotate(-90)`}
          textAnchor="middle"
        >
          Velocity (log)
        </text>
      </g>

      <g clipPath={`url(#${clipId})`} data-testid="strategy-map-plot">
        {medianX !== null && (
          <line
            x1={sx(medianX)}
            x2={sx(medianX)}
            y1={M.top}
            y2={M.top + ph}
            stroke="var(--muted-2)"
            strokeDasharray="4 4"
            data-median="x"
          />
        )}
        {medianY !== null && (
          <line
            x1={M.left}
            x2={M.left + pw}
            y1={sy(medianY)}
            y2={sy(medianY)}
            stroke="var(--muted-2)"
            strokeDasharray="4 4"
            data-median="y"
          />
        )}
        {trails.map((t) => (
          <line
            key={`t-${t.id}`}
            x1={sx(t.x0)}
            y1={sy(t.y0)}
            x2={sx(t.x1)}
            y2={sy(t.y1)}
            stroke={t.color}
            strokeOpacity={0.4}
            strokeWidth={1.5}
            data-trail={t.id}
          />
        ))}
        {points.map((d) => {
          const cx = sx(d.x);
          const cy = sy(d.y);
          return (
            <circle
              key={d.id}
              cx={cx}
              cy={cy}
              r={6}
              fill={MATURITY_COLOR[d.p.maturity] ?? "#7ba69b"}
              stroke={PLAYBOOK_COLOR[d.p.playbook]}
              strokeWidth={2}
              style={{ cursor: "pointer" }}
              data-point={d.id}
              onMouseEnter={() => setHover({ p: d.p, px: cx, py: cy })}
              onMouseLeave={() => setHover(null)}
              onClick={() => onOpenRef.current(d.id)}
            />
          );
        })}
        {labelAll &&
          points.map((d) => (
            <text
              key={`l-${d.id}`}
              x={sx(d.x)}
              y={sy(d.y) - 9}
              textAnchor="middle"
              fontSize={9}
              fill="var(--foreground)"
              pointerEvents="none"
            >
              {d.name}
            </text>
          ))}
      </g>
    </svg>
  );
});

function HoverCard({ hover, width }: { hover: Hover; width: number }) {
  const { p, px, py } = hover;
  // Pin inside the chart: flip left near the right edge, above near the bottom.
  let left = px + GAP;
  if (left + CARD_W > width) left = px - GAP - CARD_W;
  left = Math.max(0, Math.min(left, width - CARD_W));
  let top = py + GAP;
  if (top + CARD_H > HEIGHT) top = py - GAP - CARD_H;
  top = Math.max(0, Math.min(top, HEIGHT - CARD_H));

  const series = p.series_units ?? [];
  const max = Math.max(1, ...series);
  const sw = CARD_W - 24;
  const sh = 36;
  const path = series
    .map(
      (u, i) =>
        `${i === 0 ? "M" : "L"}${((i / Math.max(1, series.length - 1)) * sw).toFixed(1)},${(sh - (u / max) * sh).toFixed(1)}`,
    )
    .join(" ");

  return (
    <div
      className="pointer-events-none absolute rounded-lg px-3 py-2 text-xs shadow"
      data-testid="strategy-map-tooltip"
      style={{
        left,
        top,
        width: CARD_W,
        height: CARD_H,
        overflow: "hidden",
        background: "var(--surface)",
        border: "1px solid var(--line)",
      }}
    >
      <div className="truncate font-semibold">{p.name}</div>
      <div className="truncate">
        {PLAYBOOK_LABEL[p.playbook]} · {p.maturity} · {p.cluster_label}
      </div>
      <div>
        Now {num(p.velocity, 2)}/wk @ {pct(p.coverage)} · prime{" "}
        {num(p.prime_velocity, 2)} @ {pct(p.prime_coverage)}
      </div>
      <div>
        WH {p.wh_status ?? "–"} · {aed(p.net_rev_8w)} in 8 wk
      </div>
      <svg width={sw} height={sh} className="mt-1 block">
        <path d={path} fill="none" stroke="var(--brand)" strokeWidth={1.5} />
      </svg>
    </div>
  );
}
