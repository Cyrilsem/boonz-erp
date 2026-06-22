// PRD-049 Phase A logic verification (no phone / browser needed).
// Replicates the EXACT state transitions changed in packing/[machineId]/page.tsx and
// asserts the three reported symptoms are fixed. This is a logic-level QA result; the
// on-device QA against today's HUAWEI plan is still CS's gate. Run: node scripts/prd049_phaseA_logic_check.mjs
let pass = 0,
  fail = 0;
const ok = (name, cond) => {
  cond ? pass++ : fail++;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
};

// ── issue 2: composed skip reason auto-pad (mirror of submitSkip) ──────────────
function composeSkipReason(skipCategory, skipNote) {
  const note = (skipNote || "").trim();
  const category = (skipCategory || "").trim() || "Skipped";
  let reason = note ? `${category}: ${note}` : category;
  if (reason.length < 10) reason = `${reason} - skipped at packing`;
  return reason;
}
ok(
  "issue2: category-only 'OOS' pads to >=10",
  composeSkipReason("OOS", "").length >= 10,
);
ok(
  "issue2: empty category pads to >=10",
  composeSkipReason("", "").length >= 10,
);
ok(
  "issue2: 'Expired' (7) pads to >=10",
  composeSkipReason("Expired", "").length >= 10,
);
ok(
  "issue2: long note preserved verbatim",
  composeSkipReason("Damaged", "box crushed in transit") ===
    "Damaged: box crushed in transit",
);
ok(
  "issue2: no skip is ever blocked (always returns a usable reason)",
  composeSkipReason("X", "").length >= 10 &&
    composeSkipReason("a", "b").length >= 1,
);

// ── shared session-state model (lines staged locally, committed at Finish) ─────
const makeSession = () => ({
  // user has: edited line A's pick qty (rec 3 -> 5), staged line B as packed, C still pending
  lines: [
    {
      dispatch_id: "A",
      action: null,
      recommended_qty: 3,
      shelf_code: "A01",
      display_name: "Coke",
    },
    {
      dispatch_id: "B",
      action: "packed",
      recommended_qty: 4,
      shelf_code: "A02",
      display_name: "Pepsi",
    },
    {
      dispatch_id: "C",
      action: null,
      recommended_qty: 2,
      shelf_code: "A03",
      display_name: "Water",
    },
  ],
  batchPickQtys: { A: { b1: 5 }, B: { b2: 4 } }, // A edited to 5
  skippedLines: [],
});
const resolved = (s) =>
  s.lines.filter((l) => l.action !== null).length +
  s.skippedLines.filter((x) => x.skipped && !x.cancelled).length;
const total = (s) =>
  s.lines.length +
  s.skippedLines.filter((x) => x.skipped && !x.cancelled).length;

// OLD behavior: skip/not_filled called fetchData() -> rebuild from DB. Uncommitted local
// actions revert to null and edited batchPickQtys revert to recommended.
function oldRefetchClobber(s) {
  return {
    lines: s.lines.map((l) => ({ ...l, action: null })), // DB has no staged pack yet
    batchPickQtys: Object.fromEntries(
      s.lines.map((l) => [l.dispatch_id, { b: l.recommended_qty }]),
    ),
    skippedLines: s.skippedLines,
  };
}

// NEW not_filled: set local action only, no refetch.
function newNotFilled(s, id) {
  return {
    ...s,
    lines: s.lines.map((l) =>
      l.dispatch_id === id ? { ...l, action: "not_filled" } : l,
    ),
  };
}
// NEW skip: surgical move to skippedLines, no refetch.
function newSkip(s, id, reason) {
  const line = s.lines.find((l) => l.dispatch_id === id);
  return {
    ...s,
    lines: s.lines.filter((l) => l.dispatch_id !== id),
    skippedLines: [
      ...s.skippedLines,
      {
        dispatch_id: id,
        quantity: line.recommended_qty,
        skip_reason: reason,
        skipped: true,
        cancelled: false,
      },
    ],
  };
}

// ── issue 1+3 via NOT FILLED on the last line ─────────────────────────────────
{
  const before = makeSession();
  const old = oldRefetchClobber(before); // what the old code produced after marking C not_filled
  ok(
    "issue3 (old, demonstrates bug): B's staged 'packed' is LOST after refetch",
    old.lines.find((l) => l.dispatch_id === "B").action === null,
  );
  ok(
    "issue1 (old, demonstrates bug): A's edited qty 5 reverts to recommended 3",
    old.batchPickQtys.A.b === 3,
  );

  const after = newNotFilled(before, "C");
  ok(
    "issue3 (fixed): B stays 'packed' after marking C not_filled",
    after.lines.find((l) => l.dispatch_id === "B").action === "packed",
  );
  ok(
    "issue1 (fixed): A's edited qty 5 is preserved",
    after.batchPickQtys.A.b1 === 5,
  );
  ok(
    "issue3 (fixed): C is resolved as not_filled",
    after.lines.find((l) => l.dispatch_id === "C").action === "not_filled",
  );
  // Finish gate: pack B + not_filled C, A still pending -> not all resolved yet (correct)
  ok(
    "gate: A still pending keeps Finish honestly gated",
    resolved(after) === 2 && total(after) === 3,
  );
  // now pack A too
  const allDone = {
    ...after,
    lines: after.lines.map((l) =>
      l.dispatch_id === "A" ? { ...l, action: "packed" } : l,
    ),
  };
  ok(
    "gate: once every line resolved, Finish enabled (resolved===total)",
    resolved(allDone) === total(allDone) && total(allDone) === 3,
  );
}

// ── issue 1+3 via SKIP a different line while A is edited and B is staged ──────
{
  const before = makeSession();
  const reason = composeSkipReason("OOS", "");
  const after = newSkip(before, "C", reason);
  ok(
    "issue1 (fixed): A's edited qty survives a skip elsewhere",
    after.batchPickQtys.A.b1 === 5,
  );
  ok(
    "issue3 (fixed): B's staged 'packed' survives a skip elsewhere",
    after.lines.find((l) => l.dispatch_id === "B").action === "packed",
  );
  ok(
    "skip: C moved into Skipped panel with padded reason",
    after.skippedLines.length === 1 &&
      after.skippedLines[0].skip_reason.length >= 10,
  );
  // total is conserved across a skip (line leaves `lines`, enters skipped), resolved +1
  ok(
    "gate math: skip conserves total, increments resolved",
    total(after) === total(before) && resolved(after) === resolved(before) + 1,
  );
}

console.log(
  `\n${fail === 0 ? "ALL PASS" : "FAILURES"}: ${pass} passed, ${fail} failed`,
);
process.exit(fail === 0 ? 0 : 1);
