#!/usr/bin/env python3
"""
render_planograms.py — Phase 6/9 visual renderer for new-machine-onboarding.

Reads a locked planogram CSV and produces a single-door or double-door PNG
that's partner-shareable. Brand-styled (Boonz dark green + gold), Pod-26
4-4-3-3-2 layout, color-coded by product category, capacity numbers shown.

USAGE
-----
    python render_planograms.py \
        --planogram "BOONZ BRAIN/leads/omd-difc/machines/1/planogram.csv" \
        --format single-door \
        --output "BOONZ BRAIN/leads/omd-difc/machines/1/planogram_visual_single.png"

    # batch all machines for a lead:
    python render_planograms.py --lead-dir "BOONZ BRAIN/leads/omd-difc/"
"""

from __future__ import annotations
import argparse
import csv
import json
import sys
from pathlib import Path

# Brand-guidelines colors (Anthropic / Boonz dark theme)
BG = "#0a0d0b"
PANEL = "#141a14"
LINE = "#22291f"
INK = "#eaece1"
INK_2 = "#a9b09a"
INK_3 = "#737a68"
GOLD = "#c9a25b"
HERO = "#7fb069"
BOONZ = "#1f4d3a"

# Product-type → color (rough heuristic — refine when boonz_products gains a category column)
CATEGORY_COLORS = {
    "bar":        "#6b8e3b",  # protein/snack bars
    "biscuit":    "#a06832",  # biscuits/wafers
    "chocolate":  "#7b3f1d",
    "chips":      "#c9a25b",
    "popcorn":    "#d4b16a",
    "yogurt":     "#9bc2c2",
    "cake":       "#c5a86c",
    "drink_can":  "#5b8db5",
    "drink_bottle":"#3e6480",
    "water":      "#7aa3c2",
    "energy":     "#d97757",
    "wellness":   "#7fb069",
    "default":    "#5a6a4d",
}

CATEGORY_KEYWORDS = [
    ("water",      ["evian", "al ain", "aquafina", "perrier"]),
    ("energy",     ["red bull", "monster", "celsius"]),
    ("drink_can",  ["pepsi", "coke", "coca", "ice tea", "soft drink", "7up", "fanta", "sprite"]),
    ("drink_bottle",["vitamin well"]),
    ("wellness",   ["fade fit", "be kind", "barebells"]),
    ("chocolate",  ["mars", "snickers", "bounty", "kit kat", "kitkat", "kinder", "m&m", "mm ", "maltesers", "skittles", "chocolate"]),
    ("biscuit",    ["oreo", "mcvit", "loacker", "nutella", "biscuit"]),
    ("bar",        ["bar", "popit", "krambals", "zigi", "tamreem"]),
    ("chips",      ["hunter", "sunbites", "pringles", "chips", "g&h", "popped"]),
    ("popcorn",    ["popcorn", "dubai popcorn"]),
    ("yogurt",     ["activia", "yogurt", "hummus", "smart gourmet"]),
    ("cake",       ["sabahoo", "cake", "rice cake", "pancake"]),
]

SHELF_LAYOUT = [
    {"shelf": 1, "slots": 4, "label": "Shelf 1"},
    {"shelf": 2, "slots": 4, "label": "Shelf 2"},
    {"shelf": 3, "slots": 3, "label": "Shelf 3"},
    {"shelf": 4, "slots": 3, "label": "Shelf 4"},
    {"shelf": 5, "slots": 2, "label": "Shelf 5"},
]


def category_for(name: str) -> str:
    n = (name or "").lower()
    for cat, kws in CATEGORY_KEYWORDS:
        if any(kw in n for kw in kws):
            return cat
    return "default"


def color_for(name: str) -> str:
    return CATEGORY_COLORS.get(category_for(name), CATEGORY_COLORS["default"])


def load_csv(path: Path) -> list[dict]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def render_single_door(slots_by_door: dict[str, dict[tuple, dict]], door: str, ax, title: str):
    """Render one door's worth of shelves into a matplotlib axis."""
    ax.set_xlim(0, 4)
    ax.set_ylim(0, 5)
    ax.set_aspect("equal")
    ax.set_facecolor(PANEL)
    ax.set_title(title, color=GOLD, fontsize=11, fontweight="bold", loc="left", pad=8)
    ax.set_xticks([]); ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_color(LINE)
        spine.set_linewidth(1)

    door_slots = slots_by_door.get(door, {})

    for layout in SHELF_LAYOUT:
        shelf = layout["shelf"]
        n = layout["slots"]
        # Y position — shelf 1 at the top, shelf 5 at the bottom
        y = 5 - shelf
        slot_w = 4 / n
        for pos in range(1, n + 1):
            x = (pos - 1) * slot_w
            slot = door_slots.get((shelf, pos), {})
            name = slot.get("pod_product_name", "")
            cap = slot.get("capacity", "")
            price = slot.get("price", "")
            color = color_for(name) if name else "#1a211a"

            # Slot rectangle
            rect = _rect(ax, x + 0.04, y + 0.04, slot_w - 0.08, 0.92, color)

            # Label — pod_product_name
            if name:
                # Wrap long names
                display = name if len(name) < 18 else name[:16] + "…"
                ax.text(x + slot_w / 2, y + 0.62, display,
                        ha="center", va="center",
                        color="white", fontsize=7, fontweight="bold",
                        wrap=True)
                ax.text(x + slot_w / 2, y + 0.38, f"AED {price}",
                        ha="center", va="center",
                        color="white", fontsize=6, alpha=0.9)
                ax.text(x + slot_w / 2, y + 0.18, f"cap {cap}",
                        ha="center", va="center",
                        color="white", fontsize=6, alpha=0.7)
            else:
                ax.text(x + slot_w / 2, y + 0.5, "—",
                        ha="center", va="center",
                        color=INK_3, fontsize=10)

            # Slot code top-left
            slot_code = slot.get("slot_code", f"{chr(64+shelf)}{pos:02d}")
            ax.text(x + 0.06, y + 0.94, slot_code,
                    ha="left", va="top",
                    color=GOLD, fontsize=5.5, fontweight="bold",
                    family="monospace")


def _rect(ax, x, y, w, h, color):
    from matplotlib.patches import FancyBboxPatch
    p = FancyBboxPatch((x, y), w, h,
                       boxstyle="round,pad=0.02,rounding_size=0.04",
                       linewidth=0.8,
                       edgecolor="#0a0d0b",
                       facecolor=color)
    ax.add_patch(p)
    return p


def render(planogram_csv: Path, machine_format: str, output: Path, machine_name: str = "", venue_group: str = "", location_type: str = ""):
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("ERROR: matplotlib not installed. Run: pip install matplotlib --break-system-packages", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(planogram_csv)
    slots_by_door: dict[str, dict[tuple, dict]] = {}
    for r in rows:
        d = r.get("door", "L")
        slots_by_door.setdefault(d, {})[(int(r["shelf"]), int(r["position"]))] = r

    is_double = machine_format == "double-door"
    fig, axes = plt.subplots(1, 2 if is_double else 1, figsize=(16 if is_double else 8, 10))
    fig.patch.set_facecolor(BG)

    if is_double:
        render_single_door(slots_by_door, "L", axes[0], "Left Door")
        render_single_door(slots_by_door, "R", axes[1], "Right Door")
    else:
        render_single_door(slots_by_door, "L", axes if not is_double else axes[0], "Single Door")

    # Header
    title = machine_name or planogram_csv.stem
    subtitle_parts = [s for s in [venue_group, location_type, machine_format] if s]
    subtitle = " · ".join(subtitle_parts)
    fig.suptitle(title, color=INK, fontsize=15, fontweight="bold", x=0.05, ha="left", y=0.97)
    if subtitle:
        fig.text(0.05, 0.935, subtitle, color=INK_3, fontsize=9, ha="left", family="monospace")

    fig.text(0.95, 0.02, "Boonz · planogram", color=GOLD, fontsize=8, ha="right", family="monospace", alpha=0.6)

    plt.subplots_adjust(top=0.90, bottom=0.05, left=0.04, right=0.96, wspace=0.05)

    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output, dpi=180, facecolor=BG, edgecolor="none", bbox_inches="tight")
    plt.close(fig)
    print(f"✅ Wrote {output}")


def render_lead(lead_dir: Path):
    """Batch-render all machines for a lead."""
    machines_dir = lead_dir / "machines"
    if not machines_dir.exists():
        print(f"ERROR: {machines_dir} not found", file=sys.stderr)
        sys.exit(1)
    for machine_dir in sorted(p for p in machines_dir.iterdir() if p.is_dir()):
        plano = machine_dir / "planogram.csv"
        cfg_path = machine_dir / "config.json"
        if not plano.exists():
            print(f"⚠️  No planogram.csv in {machine_dir.name}, skipping", file=sys.stderr)
            continue
        cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
        fmt = cfg.get("pod_format", "single-door")
        out_name = "planogram_visual_double.png" if fmt == "double-door" else "planogram_visual_single.png"
        out = machine_dir / out_name
        render(
            plano, fmt, out,
            machine_name=cfg.get("planned_official_name", machine_dir.name),
            venue_group=cfg.get("venue_group", ""),
            location_type=cfg.get("location_type", ""),
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--planogram", help="path to planogram.csv (single machine)")
    ap.add_argument("--format", choices=["single-door", "double-door"], default="single-door")
    ap.add_argument("--output", help="output PNG path")
    ap.add_argument("--machine-name", default="")
    ap.add_argument("--venue-group", default="")
    ap.add_argument("--location-type", default="")
    ap.add_argument("--lead-dir", help="batch-render all machines for a lead")
    args = ap.parse_args()

    if args.lead_dir:
        render_lead(Path(args.lead_dir))
    elif args.planogram and args.output:
        render(
            Path(args.planogram), args.format, Path(args.output),
            machine_name=args.machine_name,
            venue_group=args.venue_group,
            location_type=args.location_type,
        )
    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
