#!/usr/bin/env node
/**
 * PRD-115 acceptance 3 and 4 - the FE assertions.
 *
 * Acceptance 4 says "string asserted in test". There is no JS test harness in
 * this repo and CLAUDE.md forbids adding packages without asking, so this is a
 * zero-dependency node script rather than a vitest file. It asserts the same
 * things a unit test would, against the sources that ship.
 *
 *   node scripts/prd115-fe-string-assertions.mjs
 *
 * Exit 0 = green, exit 1 = red with the failing assertion named.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PAGE = "src/app/(field)/field/packing/[machineId]/page.tsx";
const MSGS = "src/app/(field)/field/packing/_lib/pack-messages.ts";

const page = readFileSync(join(root, PAGE), "utf8");
const msgs = readFileSync(join(root, MSGS), "utf8");

const results = [];
const assert = (name, ok, detail) => results.push({ name, ok, detail });

// ── Acceptance 4: the pick-total message names the LINE and states the RULE ──
// Import the real function rather than grepping for its output: a message that
// only exists as a string literal in a test is a message that can drift.
const { pickExceedsPlanMessage, REMOVE_LEG_CHIP, REPACK_DESTRUCTIVE_WARNING } =
  await import(
    new URL(
      "../src/app/(field)/field/packing/_lib/pack-messages.ts",
      import.meta.url,
    ).href
  ).catch(() => ({}));

// Node cannot import .ts directly, so fall back to evaluating the exported
// template against the source. Both paths assert the SAME rendered string.
const rendered =
  typeof pickExceedsPlanMessage === "function"
    ? pickExceedsPlanMessage("Activia Mix & Go", 3)
    : msgs
        .match(/return `([^`]+)`;/)?.[1]
        ?.replace("${lineName}", "Activia Mix & Go")
        .replace("${plannedQty}", "3");

assert(
  "A4: pick-total message names the line",
  !!rendered && rendered.startsWith("Activia Mix & Go:"),
  rendered,
);
assert(
  "A4: pick-total message states the plan",
  !!rendered && rendered.includes("this line plans 3"),
  rendered,
);
assert(
  "A4: pick-total message states the Remove-leg rule",
  !!rendered &&
    rendered.includes(
      "Remove legs are counted separately - do not add them to your pick",
    ),
  rendered,
);
assert(
  "A4: the incident line reproduces verbatim",
  rendered ===
    "Activia Mix & Go: this line plans 3 (Remove legs are counted separately - do not add them to your pick).",
  rendered,
);

// ── Acceptance 3: ZERO per-line warning strings ─────────────────────────────
// Comments are stripped first, on purpose. The acceptance is that the string is
// never RENDERED; the code comment that explains why it was removed quotes it,
// and that comment is documentation, not a warning wall.
const pageCode = page
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/^\s*\/\/.*$/gm, "");
const perLineWarnings = [
  "already packed — refresh to edit",
  "already packed - refresh to edit",
];
for (const s of perLineWarnings) {
  assert(
    `A3: per-line warning removed (${JSON.stringify(s)})`,
    !pageCode.includes(s),
    "found in " + PAGE,
  );
}

// ── Acceptance 3: EXACTLY ONE refresh banner ────────────────────────────────
const bannerUses = (page.match(/planChangedBanner\(/g) ?? []).length;
assert(
  "A3: exactly one plan-changed banner render site",
  bannerUses === 1,
  `planChangedBanner( used ${bannerUses}x`,
);
assert(
  "A3: the drift counter feeds the banner, not a per-line list",
  /driftLines \+= 1;/.test(page) && /setPlanDrift\(driftLines\)/.test(page),
  "driftLines counter missing",
);

// ── §2.3: needs_reconfirm read from the canonical object (Cody C-5) ─────────
assert(
  "C-5: pack state is read FROM v_machine_pack_status",
  page.includes('.from("v_machine_pack_status")') &&
    page.includes("needs_reconfirm, unresolved_n"),
  "view read missing",
);
assert(
  "C-5: unresolved count is NOT re-derived for the banner",
  page.includes("packStatus?.unresolved_n"),
  "unresolved_n not read from the view",
);
assert(
  "§2.3: needs_reconfirm primary CTA is Finish remaining",
  page.includes("Finish remaining"),
  "CTA missing",
);
assert(
  "§2.3: needs_reconfirm banner and already-packed banner are mutually exclusive",
  page.includes("!isDispatchLocked && !needsReconfirm"),
  "exclusivity guard missing",
);

// ── §2.3: Override & re-pack sits behind a destructive dialog ───────────────
assert(
  "§2.3: re-pack no longer fires from a bare window.confirm",
  !/if \(\s*\n?\s*!confirm\(/.test(page) &&
    !page.includes("Override all items packed for"),
  "bare confirm() still present",
);
assert(
  "§2.3: the dialog is a real modal",
  page.includes('role="dialog"') && page.includes('aria-modal="true"'),
  "modal semantics missing",
);
const warning =
  REPACK_DESTRUCTIVE_WARNING ??
  msgs.match(/REPACK_DESTRUCTIVE_WARNING =\s*\n?\s*"([^"]+)"/)?.[1];
assert(
  "§2.3: the dialog says it returns ALL packed stock to the warehouse",
  !!warning &&
    warning.includes("returns ALL packed stock to the warehouse") &&
    page.includes("REPACK_DESTRUCTIVE_WARNING"),
  warning,
);

// ── §2.3: Remove legs carry the counts-separately chip ──────────────────────
const chip = REMOVE_LEG_CHIP ?? msgs.match(/REMOVE_LEG_CHIP = "([^"]+)"/)?.[1];
assert(
  "§2.3: the chip reads 'counts separately'",
  chip === "counts separately",
  chip,
);
const chipUses = (page.match(/\{REMOVE_LEG_CHIP\}/g) ?? []).length;
assert(
  "§2.3: the chip renders on every Remove-leg surface (swap pair, remove card, qty>0 remove)",
  chipUses >= 3,
  `REMOVE_LEG_CHIP rendered ${chipUses}x`,
);
assert(
  "§2.3: same-pod Remove legs render adjacent to their refill",
  page.includes("samePodRemoveByRefill") && page.includes("packSectionLines"),
  "adjacency pairing missing",
);

// ── report ──────────────────────────────────────────────────────────────────
let failed = 0;
for (const r of results) {
  if (!r.ok) failed += 1;
  console.log(
    `${r.ok ? "PASS" : "FAIL"}  ${r.name}${r.ok ? "" : `\n        -> ${r.detail}`}`,
  );
}
console.log(
  `\n${results.length - failed}/${results.length} PRD-115 FE assertions passed`,
);
process.exit(failed === 0 ? 0 : 1);
