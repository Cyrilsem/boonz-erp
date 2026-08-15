"use client";

// S-3 / B-2 / B-3 / B-4 — 2026-04-27
// All receipt writes now go through receive_purchase_order RPC (SECURITY DEFINER).
// Fixes:
//   B-2: No more extra INSERT per expiry batch — only the original PO line is updated
//   B-3: warehouse_inventory written via RPC, not directly from browser client
//   B-4: po_additions (field additions) are included in the RPC call and properly inventoried

import { useEffect, useState, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getDubaiDate } from "@/lib/utils/date";
import { FieldHeader } from "../../../components/field-header";

// ── Driver outcome types ──────────────────────────────────────────────────────
// Parsed from driver_tasks.outcome_comment JSON so WH can see what the driver reported

interface DriverLineOutcome {
  po_line_id: string;
  product_name: string;
  outcome: "purchased_full" | "purchased_partial" | "not_available" | "other";
  qty_purchased: number | null;
  comment: string | null;
}

// ── Types ────────────────────────────────────────────────────────────────────

interface ReceiveBatch {
  batch_key: string;
  received_qty: number;
  expiry_date: string;
}

/** PRD-022: the advisory flag procurement_price_sync_and_flag stamps. */
interface PriceFlag {
  code: string;
  unit_aed: number | null;
  total_aed: number | null;
  qty: number | null;
  peer_median_unit_aed: number | null;
  peer_observations: number | null;
  unit_vs_median_pct: number | null;
  suggested_unit_aed: number | null;
}

interface ReceiveLine {
  po_line_id: string;
  po_id: string;
  boonz_product_id: string;
  boonz_product_name: string;
  ordered_qty: number;
  received_qty: number | null;
  supplier_id: string;
  price_per_unit_aed: number | null;
  total_price_aed: number | null;
  price_flag: PriceFlag | null;
  purchase_date: string;
  wh_location: string;
  received_date: string | null;
  batches: ReceiveBatch[];
}

interface POHeader {
  po_id: string;
  supplier_name: string;
  purchase_date: string;
}

interface BoonzProduct {
  product_id: string;
  boonz_product_name: string;
  physical_type: string | null;
}

interface FieldAddition {
  addition_id: string;
  boonz_product_id: string;
  qty: number;
  price_per_unit_aed: number | null;
  total_price_aed: number | null;
  pricing_status: string;
  price_flag: PriceFlag | null;
  status: string;
  wh_location: string;
  boonz_products: { boonz_product_name: string };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function generateKey(): string {
  return Math.random().toString(36).slice(2);
}

// ── PRD-022 - total-first capture (supersedes the PRD-003 Q4 unit-first rule) ─
//
// PRD-003 Q4 had the operator type the printed UNIT price and computed the line
// total, on the reasoning that dividing a total by qty loses fils. PRD-022
// inverts it, and the fils argument now points the other way.
//
// What the bill prints, and what every cost read ultimately wants, is the LINE
// TOTAL - the cash. Capturing the total stores that figure exactly, with no
// division anywhere on the path from the paper to total_price_aed. The unit
// price becomes the derived, lossy number, which is the right one to lose fils
// on because nothing settles against it. Under the old rule the exact number
// was the one nobody pays and the rounded one was the money.
//
// It also removes an entire class of error at the source. The 2026-08-11 Union
// Coop incident was a PACK TOTAL typed into a field labelled "unit price". When
// the field asks for the total, that keystroke is simply correct.
//
// Supplier gift / bonus units (PRD-003 §12) fall out for free. A supplier can
// deliver 8 and bill 1; the bill total IS the cash for the billed units, so
// typing it stores the cash with no adjustment step, and the derived unit price
// spreads that cash over everything that landed - the same landed-cost
// treatment §12 wanted, arrived at without inflating then deflating the line.
// The "Free / bonus units" field therefore no longer changes what is stored; it
// annotates the breakdown chip so the operator can see billed vs free.
const round2 = (n: number) => Math.round(n * 100) / 100;
const round4 = (n: number) => Math.round(n * 10000) / 10000;

/**
 * The unit cost the DB will derive from the total, mirroring
 * procurement_price_sync_and_flag exactly: round(total / qty, 4).
 * Display-only - the FE never sends this.
 */
function derivedUnitAed(total: number, receivedQty: number): number | null {
  if (receivedQty <= 0) return null;
  return round4(total / receivedQty);
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function ReceivingDetailPage() {
  const params = useParams<{ poId: string }>();
  const router = useRouter();
  const poId = decodeURIComponent(params.poId);

  const [header, setHeader] = useState<POHeader | null>(null);
  const [lines, setLines] = useState<ReceiveLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);

  // PRD-022: receive by LINE TOTAL ex-VAT as printed on the supplier bill.
  // The unit price is derived and shown read-only, never typed. See the
  // total-first note at the top of this file for why this inverts PRD-003 Q4.
  const [editedTotals, setEditedTotals] = useState<
    Record<string, number | null>
  >({});

  // PRD-022: per-line "Free goods - 0.00 is correct". Required before a line
  // with an empty or zero total can be confirmed, so a missing price can never
  // be mistaken for a free delivery. Writes pricing_status='free_goods'.
  const [freeGoodsLines, setFreeGoodsLines] = useState<Set<string>>(new Set());

  // PRD-003 §12 - units delivered but NOT billed (supplier gift / bonus).
  // Keyed by po_line_id. Kept as-is per the PRD-022 decision list, but under
  // total-first it no longer alters what is stored: the typed bill total is
  // already the cash for the billed units. It drives the breakdown chip only.
  const [freeUnits, setFreeUnits] = useState<Record<string, number | null>>({});

  // PRD-003 - document-level totals, submitted AFTER receive_purchase_order
  // succeeds. Advisory only: a failure here never invalidates the receipt.
  const [discountAed, setDiscountAed] = useState<number | null>(null);
  const [discountLabel, setDiscountLabel] = useState("");
  const [vatAed, setVatAed] = useState<number | null>(null);
  const [vatEdited, setVatEdited] = useState(false);
  const [otherAdjAed, setOtherAdjAed] = useState<number | null>(null);
  const [otherAdjLabel, setOtherAdjLabel] = useState("");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [invoiceDate, setInvoiceDate] = useState("");
  const [invoiceTotal, setInvoiceTotal] = useState<number | null>(null);
  const [totalsError, setTotalsError] = useState<string | null>(null);
  const [totalsSaving, setTotalsSaving] = useState(false);

  // 90-day weighted average unit price per boonz product (received POs),
  // for the on-par / below / above purchase-price indicator.
  const [avg90, setAvg90] = useState<
    Record<string, { avg: number; n: number }>
  >({});

  // Per-addition wh_location (additions can also have a location)
  const [additionLocations, setAdditionLocations] = useState<
    Record<string, string>
  >({});

  const [receiveResults, setReceiveResults] = useState<
    { productName: string; qty: number }[]
  >([]);
  const [error, setError] = useState<string | null>(null);

  // Driver outcome report — parsed from driver_tasks.outcome_comment for this PO
  // keyed by po_line_id for O(1) lookup
  const [driverOutcomes, setDriverOutcomes] = useState<
    Map<string, DriverLineOutcome>
  >(new Map());

  // Lines the WH has explicitly marked as "not purchased" (po_line_id set)
  const [notPurchasedLines, setNotPurchasedLines] = useState<Set<string>>(
    new Set(),
  );

  // PRD-001: post-receipt edit detection
  const [postReceiptEdits, setPostReceiptEdits] = useState<
    { changed_at: string; actor_name: string | null; reason: string }[]
  >([]);

  // Field additions
  const [showAddItem, setShowAddItem] = useState(false);
  const [allProducts, setAllProducts] = useState<BoonzProduct[]>([]);
  const [addSearch, setAddSearch] = useState("");
  const [selectedProduct, setSelectedProduct] = useState<BoonzProduct | null>(
    null,
  );
  // PRD-022: the addition form captures the bill total, not a unit price, and
  // routes through create_po_addition_v2. addFreeGoods is the same explicit
  // assertion the received lines require.
  const [addTotal, setAddTotal] = useState<number>(0);
  const [addFreeGoods, setAddFreeGoods] = useState(false);
  const [addError, setAddError] = useState<string | null>(null);
  // PRD-002: multi-batch additions. Each batch becomes one po_additions row.
  // Same price across batches (price is per-product on the PO line, not per
  // batch). Default single-batch state preserves the prior UX.
  const [addBatches, setAddBatches] = useState<
    { qty: number; expiry: string }[]
  >([{ qty: 1, expiry: "" }]);
  const [addSaving, setAddSaving] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [additions, setAdditions] = useState<FieldAddition[]>([]);

  // ── Data fetch ──────────────────────────────────────────────────────────────

  const fetchData = useCallback(async () => {
    const supabase = createClient();

    const { data: poLines } = await supabase
      .from("purchase_orders")
      .select(
        `
        po_line_id,
        po_id,
        purchase_date,
        ordered_qty,
        received_qty,
        expiry_date,
        received_date,
        boonz_product_id,
        supplier_id,
        price_per_unit_aed,
        total_price_aed,
        price_flag,
        boonz_products!inner(boonz_product_name),
        suppliers!inner(supplier_name)
      `,
      )
      .eq("po_id", poId);

    const [{ data: productsData }, { data: additionsData }] = await Promise.all(
      [
        supabase
          .from("boonz_products")
          .select("product_id, boonz_product_name, physical_type")
          .order("boonz_product_name")
          .limit(10000),
        supabase
          .from("po_additions")
          .select(
            "addition_id, boonz_product_id, qty, price_per_unit_aed, total_price_aed, pricing_status, price_flag, status, boonz_products(boonz_product_name)",
          )
          .eq("po_id", poId)
          .limit(10000),
      ],
    );
    setAllProducts((productsData ?? []) as unknown as BoonzProduct[]);
    // Initialise addition locations from existing state
    const initLocations: Record<string, string> = {};
    (additionsData ?? []).forEach((a) => {
      initLocations[(a as unknown as FieldAddition).addition_id] = "";
    });
    setAdditionLocations(initLocations);
    setAdditions(
      (additionsData ?? []).map((a) => ({
        ...(a as unknown as FieldAddition),
        wh_location: "",
      })),
    );

    // Fetch driver task outcome for this PO (so WH can see driver's field report)
    const { data: taskData } = await supabase
      .from("driver_tasks")
      .select("outcome_comment, status")
      .eq("po_id", poId)
      .not("outcome_comment", "is", null)
      .limit(1)
      .single();

    if (taskData?.outcome_comment) {
      try {
        const parsed = taskData.outcome_comment as {
          lines?: DriverLineOutcome[];
        };
        const outcomeMap = new Map<string, DriverLineOutcome>();
        (parsed.lines ?? []).forEach((l) => outcomeMap.set(l.po_line_id, l));
        setDriverOutcomes(outcomeMap);

        // Pre-mark lines as "not purchased" when driver reported not_available
        // WH can override by un-checking, but this saves clicks for obvious cases
        const autoPurchaseLines = new Set<string>();
        (parsed.lines ?? []).forEach((l) => {
          if (l.outcome === "not_available")
            autoPurchaseLines.add(l.po_line_id);
        });
        if (autoPurchaseLines.size > 0) setNotPurchasedLines(autoPurchaseLines);
      } catch {
        // Malformed outcome_comment — ignore silently
      }
    }

    if (!poLines || poLines.length === 0) {
      setLines([]);
      setLoading(false);
      return;
    }

    const first = poLines[0];
    const s = first.suppliers as unknown as { supplier_name: string };
    setHeader({
      po_id: first.po_id,
      supplier_name: s.supplier_name,
      purchase_date: first.purchase_date,
    });

    const mapped: ReceiveLine[] = poLines.map((line) => {
      const p = line.boonz_products as unknown as {
        boonz_product_name: string;
      };
      return {
        po_line_id: line.po_line_id,
        po_id: line.po_id,
        boonz_product_id: line.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        ordered_qty: line.ordered_qty ?? 0,
        received_qty: (line.received_qty as number | null) ?? null,
        supplier_id: (line.supplier_id as string) ?? "",
        price_per_unit_aed: (line.price_per_unit_aed as number | null) ?? null,
        total_price_aed: (line.total_price_aed as number | null) ?? null,
        price_flag: (line.price_flag as PriceFlag | null) ?? null,
        purchase_date: line.purchase_date,
        wh_location: "",
        received_date: (line.received_date as string | null) ?? null,
        batches: [
          {
            batch_key: generateKey(),
            received_qty: line.ordered_qty ?? 0,
            expiry_date: (line.expiry_date as string | null) ?? "",
          },
        ],
      };
    });

    mapped.sort((a, b) =>
      a.boonz_product_name.localeCompare(b.boonz_product_name),
    );
    setLines(mapped);

    // Pre-fill WH locations from most recent active batch per product
    const productIds = mapped.map((l) => l.boonz_product_id);

    // PRD-087 R: 90-day weighted average purchase price per product
    // (received PO lines only) → drives the on-par/below/above indicator.
    if (productIds.length > 0) {
      const since = new Date();
      since.setDate(since.getDate() - 90);
      const { data: priceHist } = await supabase
        .from("purchase_orders")
        .select("boonz_product_id, price_per_unit_aed, received_qty")
        .in("boonz_product_id", productIds)
        .eq("purchase_outcome", "received")
        .gte("received_date", since.toISOString().slice(0, 10))
        .not("price_per_unit_aed", "is", null)
        .limit(10000);
      if (priceHist) {
        const acc = new Map<string, { v: number; q: number; n: number }>();
        for (const r of priceHist as {
          boonz_product_id: string;
          price_per_unit_aed: number;
          received_qty: number | null;
        }[]) {
          const q = Number(r.received_qty) || 1;
          const cur = acc.get(r.boonz_product_id) ?? { v: 0, q: 0, n: 0 };
          cur.v += Number(r.price_per_unit_aed) * q;
          cur.q += q;
          cur.n += 1;
          acc.set(r.boonz_product_id, cur);
        }
        const out: Record<string, { avg: number; n: number }> = {};
        acc.forEach((c, id) => {
          if (c.q > 0) out[id] = { avg: c.v / c.q, n: c.n };
        });
        setAvg90(out);
      }
    }

    if (productIds.length > 0) {
      const { data: locationData } = await supabase
        .from("warehouse_inventory")
        .select("boonz_product_id, wh_location")
        .in("boonz_product_id", productIds)
        .not("wh_location", "is", null)
        .eq("status", "Active")
        .order("created_at", { ascending: false });

      if (locationData) {
        const locationMap = new Map<string, string>();
        for (const row of locationData) {
          if (!locationMap.has(row.boonz_product_id) && row.wh_location) {
            locationMap.set(row.boonz_product_id, row.wh_location);
          }
        }
        setLines((prev) =>
          prev.map((l) => ({
            ...l,
            wh_location: locationMap.get(l.boonz_product_id) ?? l.wh_location,
          })),
        );
      }
    }

    // PRD-001: detect post-receipt edits. Compare each edit event's changed_at
    // to its line's received_date — surface a banner if the WH manager (or anyone)
    // edited the PO line after receipt.
    const lineReceiptByPk = new Map<string, string>();
    mapped.forEach((l) => {
      if (l.received_date) lineReceiptByPk.set(l.po_line_id, l.received_date);
    });
    if (lineReceiptByPk.size > 0) {
      const { data: history } = await supabase.rpc("get_po_edit_history", {
        p_po_id: poId,
      });
      if (history) {
        const postReceipt = (
          history as {
            changed_at: string;
            po_line_id: string;
            actor_name: string | null;
            reason: string;
          }[]
        )
          .filter((ev) => {
            const recv = lineReceiptByPk.get(ev.po_line_id);
            if (!recv) return false;
            // received_date is a date (YYYY-MM-DD); changed_at is a timestamptz.
            // Compare against end-of-day in UTC of received_date as a coarse cutoff.
            const recvEnd = new Date(recv + "T23:59:59Z").getTime();
            return new Date(ev.changed_at).getTime() > recvEnd;
          })
          .map((ev) => ({
            changed_at: ev.changed_at,
            actor_name: ev.actor_name,
            reason: ev.reason,
          }));
        setPostReceiptEdits(postReceipt);
      }
    }

    setLoading(false);
  }, [poId]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // ── Batch management ────────────────────────────────────────────────────────

  function addBatch(poLineId: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: [
                ...l.batches,
                { batch_key: generateKey(), received_qty: 0, expiry_date: "" },
              ],
            },
      ),
    );
  }

  function removeBatch(poLineId: string, batchKey: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: l.batches.filter((b) => b.batch_key !== batchKey),
            },
      ),
    );
  }

  function updateBatch(
    poLineId: string,
    batchKey: string,
    field: "received_qty" | "expiry_date",
    value: string | number,
  ) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: l.batches.map((b) =>
                b.batch_key !== batchKey ? b : { ...b, [field]: value },
              ),
            },
      ),
    );
  }

  function updateWHLocation(poLineId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId ? l : { ...l, wh_location: value },
      ),
    );
  }

  // ── Not-purchased helpers ───────────────────────────────────────────────────

  function toggleNotPurchased(poLineId: string) {
    setNotPurchasedLines((prev) => {
      const next = new Set(prev);
      if (next.has(poLineId)) next.delete(poLineId);
      else next.add(poLineId);
      return next;
    });
  }

  // ── Confirm receipt via RPC ─────────────────────────────────────────────────

  async function handleConfirm() {
    setSubmitting(true);
    setError(null);

    const supabase = createClient();
    const today = getDubaiDate();

    // Build lines payload for the RPC
    // Each unreceived line is either: closed as not_purchased, or has batches to receive
    const rpcLines = lines
      .filter((l) => !l.received_date)
      .map((l) => {
        // Not-purchased path: close the line with zero received
        if (notPurchasedLines.has(l.po_line_id)) {
          return {
            po_line_id: l.po_line_id,
            close_as_not_purchased: true,
          };
        }

        // PRD-022: the typed LINE TOTAL is what the bill printed, and it goes to
        // the RPC untouched. No division on the path from paper to
        // total_price_aed; the trigger derives the unit price from it.
        const typedTotal = editedTotals[l.po_line_id];
        const lineTotal =
          typedTotal != null ? typedTotal : (l.total_price_aed ?? null);

        // Free goods is an explicit assertion, never an inference from a blank
        // field. Anything else with no total is simply sent without one, and
        // the trigger flags it UNPRICED_RECEIPT - advisory, never blocking.
        const isFreeGoods = freeGoodsLines.has(l.po_line_id);

        return {
          po_line_id: l.po_line_id,
          total_price_aed: isFreeGoods ? 0 : (lineTotal ?? null),
          pricing_status: isFreeGoods ? "free_goods" : "priced",
          wh_location: l.wh_location || null,
          close_as_not_purchased: false,
          batches: l.batches
            .filter((b) => b.received_qty > 0)
            .map((b) => ({
              received_qty: b.received_qty,
              expiry_date: b.expiry_date || null,
            })),
        };
      })
      // Include both not_purchased lines AND lines with actual batches
      .filter(
        (l) => l.close_as_not_purchased || (l.batches && l.batches.length > 0),
      );

    // Build additions payload (pending_receive only)
    const rpcAdditions = additions
      .filter((a) => a.status === "pending_receive")
      .map((a) => ({
        addition_id: a.addition_id,
        boonz_product_id: a.boonz_product_id,
        qty: a.qty,
        // PRD-022: the addition already carries its own priced/free_goods
        // assertion from create_po_addition_v2. Pass it through so the receive
        // does not silently reclassify it.
        pricing_status: a.pricing_status ?? "priced",
        wh_location: additionLocations[a.addition_id] || null,
      }));

    if (rpcLines.length === 0 && rpcAdditions.length === 0) {
      setError("Nothing to receive — all quantities are zero");
      setSubmitting(false);
      return;
    }

    // S-3: single RPC call handles everything atomically
    const { data: rpcResult, error: rpcError } = await supabase.rpc(
      "receive_purchase_order",
      {
        p_po_id: poId,
        p_lines: rpcLines,
        p_additions: rpcAdditions,
      },
    );

    if (rpcError) {
      console.error("[Receiving] receive_purchase_order error:", rpcError);
      // Surface readable errors to the operator
      let msg = "Failed to save — please try again";
      if (rpcError.message.includes("not authorized")) {
        msg =
          "Permission denied — only warehouse staff can confirm receipt. Contact your manager.";
      } else if (rpcError.message.includes("not found in PO")) {
        msg = "PO line mismatch — please refresh the page and try again.";
      } else if (rpcError.message) {
        msg = rpcError.message;
      }
      setError(msg);
      setSubmitting(false);
      return;
    }

    const result = rpcResult as {
      ok: boolean;
      lines_received: number;
      additions_received: number;
    };
    console.log("[Receiving] receipt confirmed:", result);

    // Build results list for success screen (skip not-purchased lines — no batches)
    const resultsList: { productName: string; qty: number }[] = [];
    for (const l of rpcLines) {
      if (l.close_as_not_purchased) continue;
      const lineData = lines.find((ll) => ll.po_line_id === l.po_line_id);
      const totalQty = (l.batches ?? []).reduce(
        (s, b) => s + b.received_qty,
        0,
      );
      if (lineData && totalQty > 0) {
        resultsList.push({
          productName: lineData.boonz_product_name,
          qty: totalQty,
        });
      }
    }
    for (const a of rpcAdditions) {
      const addData = additions.find((aa) => aa.addition_id === a.addition_id);
      if (addData) {
        resultsList.push({
          productName:
            addData.boonz_products.boonz_product_name + " (addition)",
          qty: a.qty,
        });
      }
    }

    // PRD-003 §6.1: document totals go in a SECOND call, after the receipt has
    // landed. If this fails the receipt still stands - a driver at the warehouse
    // door must not lose a confirmed receipt to a paperwork call. The retry
    // affordance is the totals card, which stays on screen with its error.
    await saveDocumentTotals();

    setReceiveResults(resultsList);
    setSubmitted(true);
    setSubmitting(false);
  }

  // PRD-003 - the totals writer. Never blocks, never raises into the receipt.
  async function saveDocumentTotals(): Promise<boolean> {
    setTotalsSaving(true);
    setTotalsError(null);
    const supabase = createClient();
    const { error: totErr } = await supabase.rpc("set_po_document_totals", {
      p_po_id: poId,
      p_discount_aed: discountAed ?? 0,
      p_discount_label: discountLabel.trim() || null,
      // NULL = let the RPC compute it at p_vat_rate. Only send a figure when the
      // operator actually overrode the auto value.
      p_vat_aed: vatEdited ? (vatAed ?? 0) : null,
      p_vat_rate: 0.05,
      p_other_adjustment_aed: otherAdjAed ?? 0,
      p_other_adjustment_label: otherAdjLabel.trim() || null,
      p_supplier_invoice_number: invoiceNumber.trim() || null,
      p_supplier_invoice_date: invoiceDate || null,
      p_supplier_invoice_total_aed: invoiceTotal,
      p_source: "receiving",
      // PRD-003 §12: lines captured through the Q4 unit-price field are ex-VAT
      // by construction. Legacy POs stay 'unknown' - see the migration comment.
      p_line_price_regime: "ex_vat",
    });
    setTotalsSaving(false);
    if (totErr) {
      console.error("[Receiving] set_po_document_totals error:", totErr);
      setTotalsError(
        `Totals not saved: ${totErr.message}. The receipt itself is confirmed - retry the totals below.`,
      );
      return false;
    }
    return true;
  }

  // ── Field addition helpers ──────────────────────────────────────────────────

  async function handleAddConfirm() {
    if (!selectedProduct) return;

    // PRD-002: prune empty rows and validate.
    const cleanBatches = addBatches
      .map((b) => ({
        qty: Number(b.qty) || 0,
        expiry: b.expiry.trim(),
      }))
      .filter((b) => b.qty > 0);

    if (cleanBatches.length === 0) {
      alert("Add at least one batch with quantity > 0.");
      return;
    }

    // PRD-002: block save only if EVERY batch is empty-expiry. Mixed (some
    // with, some without) is allowed. Mirrors the existing
    // tg_warn_wh_inventory_null_expiry rationale.
    if (cleanBatches.every((b) => !b.expiry)) {
      alert(
        "At least one batch must have an expiry date. If the product truly has no expiry, contact a manager.",
      );
      return;
    }

    // PRD-022: the total is per-PRODUCT as printed on the bill, but a multi-
    // batch add splits one delivered quantity across expiry dates. Apportion the
    // bill total across the batches by quantity so the rows sum back to exactly
    // what was billed, and give the last batch the rounding remainder rather
    // than letting fils evaporate.
    const totalQty = cleanBatches.reduce((s, b) => s + b.qty, 0);
    let allocated = 0;
    const batchTotals = cleanBatches.map((b, i) => {
      if (addFreeGoods) return 0;
      if (i === cleanBatches.length - 1) return round2(addTotal - allocated);
      const share = round2((addTotal * b.qty) / totalQty);
      allocated = round2(allocated + share);
      return share;
    });

    if (!addFreeGoods && !(addTotal > 0)) {
      setAddError(
        "Enter the total price from the bill, or tick “Free goods” if 0.00 is correct.",
      );
      return;
    }

    setAddSaving(true);
    setAddError(null);
    const supabase = createClient();

    // PRD-022: no direct table write. create_po_addition_v2 is the canonical
    // writer — it validates the priced/free_goods contract, derives the unit
    // price, and lands a write_audit_log row (Articles 1, 4, 8).
    for (let i = 0; i < cleanBatches.length; i++) {
      const b = cleanBatches[i];
      const { data, error: rpcErr } = await supabase.rpc(
        "create_po_addition_v2",
        {
          p_po_id: poId,
          p_boonz_product_id: selectedProduct.product_id,
          p_qty: b.qty,
          p_total_price_aed: batchTotals[i],
          p_expiry_date: b.expiry || null,
          p_wh_location: null,
          p_notes: null,
          p_pricing_status: addFreeGoods ? "free_goods" : "priced",
        },
      );

      const res = data as { status?: string; error?: string } | null;
      if (rpcErr || res?.status !== "ok") {
        setAddSaving(false);
        setAddError(
          rpcErr?.message ??
            res?.error ??
            "Add failed — please check the price and try again.",
        );
        // Partial batches may already exist; refresh so the operator sees what
        // actually landed rather than guessing.
        fetchData();
        return;
      }
    }

    setAddSaving(false);
    setShowAddItem(false);
    setSelectedProduct(null);
    setAddSearch("");
    setAddBatches([{ qty: 1, expiry: "" }]);
    setAddTotal(0);
    setAddFreeGoods(false);
    setToast(
      cleanBatches.length === 1
        ? "Added!"
        : `Added ${cleanBatches.length} batches!`,
    );
    setTimeout(() => setToast(null), 2000);
    fetchData();
  }

  // ── Render states ───────────────────────────────────────────────────────────

  if (loading) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading PO details…</p>
        </div>
      </>
    );
  }

  if (submitted) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <div className="mb-4 rounded-full bg-green-100 p-4 dark:bg-green-900">
            <span className="text-2xl">✓</span>
          </div>
          <h2 className="mb-2 text-lg font-semibold">Received ✓</h2>
          <p className="mb-4 text-sm text-neutral-500">
            {header?.po_id} has been received into inventory
          </p>
          {receiveResults.length > 0 && (
            <div className="mb-4 w-full max-w-sm rounded-lg border border-green-200 bg-green-50 p-3 text-left dark:border-green-900 dark:bg-green-950/30">
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-green-700 dark:text-green-400">
                Added to warehouse
              </p>
              {receiveResults.map((r, i) => (
                <p
                  key={i}
                  className="py-1 text-xs text-green-800 dark:text-green-300"
                >
                  ✓ {r.qty} units of {r.productName}
                </p>
              ))}
            </div>
          )}
          {/* PRD-003 §6.1: the retry affordance has to live HERE. This screen
              replaces the form on submit, so an error surfaced on the totals
              card would be unreachable the moment it mattered. The receipt is
              already in inventory - only the paperwork failed. */}
          {totalsError && (
            <div className="mb-4 w-full max-w-sm rounded-lg border border-amber-200 bg-amber-50 p-3 text-left dark:border-amber-900 dark:bg-amber-950/30">
              <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-400">
                Invoice totals not saved
              </p>
              <p className="text-xs text-amber-800 dark:text-amber-300">
                {totalsError}
              </p>
              <button
                onClick={() => void saveDocumentTotals()}
                disabled={totalsSaving}
                className="mt-2 rounded border border-amber-300 px-3 py-1.5 text-xs font-medium text-amber-800 disabled:opacity-50 dark:border-amber-800 dark:text-amber-300"
              >
                {totalsSaving ? "Retrying…" : "Retry saving totals"}
              </button>
            </div>
          )}
          {totalsError === null && totalsSaving === false && (
            <p className="mb-4 text-xs text-neutral-400">
              Invoice totals saved.
            </p>
          )}
          <button
            onClick={() => router.push("/field/receiving")}
            className="rounded-lg bg-neutral-900 px-6 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Back to receiving
          </button>
        </div>
      </>
    );
  }

  if (lines.length === 0 && additions.length === 0) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No lines found for this PO
          </p>
          <button
            onClick={() => router.back()}
            className="mt-4 text-sm text-neutral-500 hover:text-neutral-700"
          >
            ← Back
          </button>
        </div>
      </>
    );
  }

  const pendingAdditions = additions.filter(
    (a) => a.status === "pending_receive",
  );
  // A line is actionable if: not yet received AND (has a not-purchased mark OR has batch qty > 0)
  const hasUnreceived = lines.some((l) => !l.received_date);
  const hasActionableLines =
    hasUnreceived &&
    lines.some(
      (l) =>
        !l.received_date &&
        (notPurchasedLines.has(l.po_line_id) ||
          l.batches.some((b) => b.received_qty > 0)),
    );
  // PRD-002 follow-up: detect partial-receive state. Some lines have already
  // been received in a prior session; the WH manager came back to receive
  // more (and may need to add a new item that arrived late). The Add item
  // button below + the receive RPC both already handle this, but the banner
  // makes the affordance unmistakable so CS / Simran don't think the page
  // is read-only.
  const hasReceivedLines = lines.some((l) => l.received_date);
  const isPartialReceive = hasReceivedLines && hasUnreceived;

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Receive Delivery" />

      {header && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{header.po_id}</h1>
          <p className="text-sm text-neutral-500">{header.supplier_name}</p>
          <p className="text-xs text-neutral-400">
            {formatDate(header.purchase_date)}
          </p>
        </div>
      )}

      {/* PRD-002 follow-up: partial-receive banner so the add-item path is
          discoverable when the WH manager came back for a second receive
          session on the same PO. */}
      {isPartialReceive && (
        <div className="mb-4 rounded-lg border border-blue-200 bg-blue-50 px-3 py-2 dark:border-blue-900 dark:bg-blue-950/30">
          <p className="text-sm font-medium text-blue-900 dark:text-blue-200">
            Partial receive — some lines already received
          </p>
          <p className="mt-1 text-xs text-blue-800 dark:text-blue-300">
            You can still receive the remaining lines and use{" "}
            <span className="font-semibold">+ Add item not on PO</span> below to
            add anything new the supplier brought. Tap{" "}
            <span className="font-semibold">Confirm receipt</span> when done.
          </p>
        </div>
      )}

      {/* PRD-001: post-receipt edit warning banner. */}
      {postReceiptEdits.length > 0 && (
        <div className="mb-4 rounded-lg border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-950">
          <p className="text-sm font-medium text-amber-900 dark:text-amber-200">
            ⚠ PO edited after receipt ({postReceiptEdits.length} change
            {postReceiptEdits.length === 1 ? "" : "s"})
          </p>
          <p className="mt-1 text-xs text-amber-800 dark:text-amber-300">
            Inventory rows already in <code>warehouse_inventory</code> are not
            updated automatically — reconcile via the Inventory page if needed.
          </p>
          <ul className="mt-2 space-y-1">
            {postReceiptEdits.slice(0, 3).map((ev, i) => (
              <li
                key={i}
                className="text-xs text-amber-800 dark:text-amber-300"
              >
                <span className="font-medium">
                  {ev.actor_name ?? "Someone"}
                </span>{" "}
                · {new Date(ev.changed_at).toLocaleString()} ·{" "}
                <span className="italic">&ldquo;{ev.reason}&rdquo;</span>
              </li>
            ))}
            {postReceiptEdits.length > 3 && (
              <li className="text-xs text-amber-700 dark:text-amber-400">
                +{postReceiptEdits.length - 3} more — see Edit history on the
                Orders page.
              </li>
            )}
          </ul>
        </div>
      )}

      <ul className="space-y-4">
        {lines.map((line) => {
          const isReceived = !!line.received_date;

          // Already received — compact read-only card
          if (isReceived) {
            return (
              <li
                key={line.po_line_id}
                className="rounded-lg border border-green-200 bg-green-50 p-4 opacity-70 dark:border-green-900 dark:bg-green-950/30"
              >
                <div className="flex items-center justify-between">
                  <p className="text-sm font-bold text-neutral-700 dark:text-neutral-300">
                    {line.boonz_product_name}
                  </p>
                  <span className="shrink-0 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                    Received ✓
                  </span>
                </div>
                <p className="mt-1 text-xs text-neutral-500">
                  {line.received_qty ?? line.ordered_qty} of {line.ordered_qty}{" "}
                  units · {formatDate(line.received_date!)}
                  {line.received_qty !== null &&
                    line.received_qty < line.ordered_qty && (
                      <span className="ml-1 font-medium text-amber-600 dark:text-amber-400">
                        ({line.ordered_qty - line.received_qty} short)
                      </span>
                    )}
                </p>
              </li>
            );
          }

          const batchTotal = line.batches.reduce(
            (sum, b) => sum + b.received_qty,
            0,
          );
          const totalColor =
            batchTotal === line.ordered_qty
              ? "text-green-600 dark:text-green-400"
              : batchTotal > line.ordered_qty
                ? "text-red-600 dark:text-red-400"
                : "text-amber-600 dark:text-amber-400";

          const isNotPurchased = notPurchasedLines.has(line.po_line_id);
          const driverReport = driverOutcomes.get(line.po_line_id);

          // Pre-fill received_qty hint from driver's partial purchase report
          const driverHintQty =
            driverReport?.outcome === "purchased_partial"
              ? driverReport.qty_purchased
              : null;

          return (
            <li
              key={line.po_line_id}
              className={`rounded-lg border p-4 ${
                isNotPurchased
                  ? "border-red-200 bg-red-50 opacity-80 dark:border-red-900 dark:bg-red-950/30"
                  : "border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
              }`}
            >
              {/* Product header */}
              <div className="mb-1 flex items-start justify-between gap-2">
                <p className="text-sm font-bold">{line.boonz_product_name}</p>
                {/* Not purchased toggle */}
                <button
                  onClick={() => toggleNotPurchased(line.po_line_id)}
                  className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-semibold transition-colors ${
                    isNotPurchased
                      ? "bg-red-200 text-red-800 dark:bg-red-900 dark:text-red-200"
                      : "bg-neutral-100 text-neutral-500 hover:bg-red-100 hover:text-red-700 dark:bg-neutral-800 dark:text-neutral-400"
                  }`}
                >
                  {isNotPurchased ? "✗ Not purchased" : "Mark not purchased"}
                </button>
              </div>

              {/* Driver report hint */}
              {driverReport && !isNotPurchased && (
                <div
                  className={`mb-2 rounded-md px-2 py-1.5 text-xs ${
                    driverReport.outcome === "not_available"
                      ? "bg-red-50 text-red-700 dark:bg-red-950/30 dark:text-red-400"
                      : driverReport.outcome === "purchased_partial"
                        ? "bg-amber-50 text-amber-700 dark:bg-amber-950/30 dark:text-amber-400"
                        : "bg-green-50 text-green-700 dark:bg-green-950/30 dark:text-green-400"
                  }`}
                >
                  <span className="font-semibold">Driver report: </span>
                  {driverReport.outcome === "not_available" &&
                    "❌ Not available at store"}
                  {driverReport.outcome === "purchased_full" &&
                    "✅ Purchased in full"}
                  {driverReport.outcome === "purchased_partial" &&
                    `⚠️ Partial — bought ${driverReport.qty_purchased ?? "?"} units`}
                  {driverReport.outcome === "other" &&
                    `📝 Other${driverReport.comment ? `: ${driverReport.comment}` : ""}`}
                </div>
              )}

              {isNotPurchased ? (
                <p className="mt-1 text-xs text-red-600 dark:text-red-400">
                  This item will be closed as not purchased. No stock will be
                  added.
                </p>
              ) : (
                <>
                  <p className="mb-3 text-xs text-neutral-500">
                    Ordered: {line.ordered_qty} units
                    {driverHintQty != null && (
                      <span className="ml-2 font-medium text-amber-600 dark:text-amber-400">
                        · Driver bought {driverHintQty}
                      </span>
                    )}
                  </p>

                  {/* Sub-batch rows — each creates a separate warehouse_inventory row
                  but does NOT create a new PO line (B-2 fix) */}
                  <div className="space-y-3">
                    {line.batches.map((batch, bIdx) => (
                      <div
                        key={batch.batch_key}
                        className="ml-2 rounded-lg border border-neutral-100 bg-neutral-50 p-3 dark:border-neutral-700 dark:bg-neutral-900"
                      >
                        <div className="mb-2 flex items-center justify-between">
                          <span className="text-xs font-semibold text-neutral-500">
                            Expiry batch {bIdx + 1}
                          </span>
                          {line.batches.length > 1 && (
                            <button
                              onClick={() =>
                                removeBatch(line.po_line_id, batch.batch_key)
                              }
                              className="text-xs text-red-500 hover:text-red-700 dark:text-red-400"
                            >
                              × remove
                            </button>
                          )}
                        </div>

                        <div className="grid grid-cols-2 gap-2">
                          <div>
                            <label className="mb-0.5 block text-xs text-neutral-500">
                              Qty
                            </label>
                            <input
                              type="number"
                              min={0}
                              value={batch.received_qty}
                              onChange={(e) =>
                                updateBatch(
                                  line.po_line_id,
                                  batch.batch_key,
                                  "received_qty",
                                  parseFloat(e.target.value) || 0,
                                )
                              }
                              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                            />
                          </div>
                          <div>
                            <label className="mb-0.5 block text-xs text-neutral-500">
                              Expiry date
                            </label>
                            <input
                              type="date"
                              value={batch.expiry_date}
                              onChange={(e) =>
                                updateBatch(
                                  line.po_line_id,
                                  batch.batch_key,
                                  "expiry_date",
                                  e.target.value,
                                )
                              }
                              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                            />
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>

                  {/* Add batch button */}
                  <button
                    onClick={() => addBatch(line.po_line_id)}
                    className="mt-2 text-xs font-medium text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
                  >
                    + Add expiry batch
                  </button>

                  {/* Running total */}
                  <p className={`mt-2 text-xs font-medium ${totalColor}`}>
                    {batchTotal} of {line.ordered_qty} to receive
                  </p>

                  {/* Warehouse location */}
                  <div className="mt-3">
                    <label className="mb-0.5 block text-xs text-neutral-500">
                      Warehouse location
                    </label>
                    <input
                      type="text"
                      value={line.wh_location}
                      onChange={(e) =>
                        updateWHLocation(line.po_line_id, e.target.value)
                      }
                      placeholder="e.g. A-01"
                      className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </div>

                  {/* PRD-022: capture the LINE TOTAL ex-VAT exactly as printed
                      on the bill (a Union Coop line reads QTY / UNIT PRICE /
                      VAT / AMT - capture AMT). The unit price is derived and
                      shown read-only. Benchmarked against the product's 90-day
                      weighted average purchase price, inverted: the derived
                      unit is what gets compared. */}
                  <div className="mt-3">
                    {/* PRD-022: the flag the DB already stamped on this line. */}
                    {line.price_flag && (
                      <div className="mb-2 rounded border border-amber-300 bg-amber-50 px-2 py-1.5 text-xs text-amber-800 dark:border-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                        <span className="font-semibold">
                          ⚠ {line.price_flag.code.replace(/_/g, " ")}
                        </span>
                        {line.price_flag.peer_median_unit_aed != null && (
                          <>
                            {" "}
                            — recorded at{" "}
                            {Number(line.price_flag.unit_aed ?? 0).toFixed(
                              2,
                            )}{" "}
                            /unit against a peer median of{" "}
                            {Number(
                              line.price_flag.peer_median_unit_aed,
                            ).toFixed(2)}
                            .
                          </>
                        )}
                        {line.price_flag.suggested_unit_aed != null && (
                          <span className="font-medium">
                            {" "}
                            Did you mean{" "}
                            {Number(line.price_flag.suggested_unit_aed).toFixed(
                              2,
                            )}{" "}
                            /unit?
                          </span>
                        )}
                      </div>
                    )}
                    <label className="mb-0.5 flex items-center gap-1.5 text-xs text-neutral-500">
                      Total price ex-VAT (AED) - as printed on the bill
                      {editedTotals[line.po_line_id] != null && (
                        <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold text-amber-700 dark:bg-amber-900/40 dark:text-amber-400">
                          edited
                        </span>
                      )}
                    </label>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      disabled={freeGoodsLines.has(line.po_line_id)}
                      value={
                        // "key present" = the user has touched the field —
                        // show exactly what they typed (empty stays empty,
                        // it must NOT snap back to the prefilled total).
                        freeGoodsLines.has(line.po_line_id)
                          ? ""
                          : line.po_line_id in editedTotals
                            ? (editedTotals[line.po_line_id] ?? "")
                            : (line.total_price_aed ?? "")
                      }
                      onChange={(e) => {
                        const val =
                          e.target.value === ""
                            ? null
                            : parseFloat(e.target.value);
                        setEditedTotals((prev) => ({
                          ...prev,
                          [line.po_line_id]: val,
                        }));
                      }}
                      placeholder="0.00"
                      className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 disabled:bg-neutral-100 disabled:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900 dark:disabled:bg-neutral-800"
                    />
                    {(() => {
                      if (freeGoodsLines.has(line.po_line_id)) {
                        return (
                          <p className="mt-1 rounded bg-emerald-50 px-2 py-1 text-xs text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-300">
                            Free goods — this line will be stored at 0.00 and
                            will not be price-flagged.
                          </p>
                        );
                      }

                      const typed = editedTotals[line.po_line_id];
                      const total =
                        typed != null ? typed : (line.total_price_aed ?? null);
                      const hist = avg90[line.boonz_product_id];
                      if (total == null)
                        return (
                          <p className="mt-1 text-xs text-neutral-400">
                            Enter the bill total to derive the unit price, or
                            tick “Free goods” below.
                          </p>
                        );

                      const unit = derivedUnitAed(total, batchTotal);
                      if (unit == null)
                        return (
                          <p className="mt-1 text-xs text-neutral-400">
                            Enter a received quantity to derive the unit price.
                          </p>
                        );

                      // PRD-022 sanity chip, inverted. Under total-first the
                      // classic slip is the reverse of the 2026-08-11 Union Coop
                      // incident: typing a UNIT price into a field that asks for
                      // the total. That lands a derived unit far BELOW the
                      // trailing average, so that is what we warn on. A derived
                      // unit far above still warns - it is either a real price
                      // rise or a wrong received quantity.
                      const unitPriceSuspect =
                        hist != null && batchTotal > 1 && unit < hist.avg / 3;
                      const highSuspect = hist != null && unit > 3 * hist.avg;
                      const diffPct = hist
                        ? ((unit - hist.avg) / hist.avg) * 100
                        : null;
                      const tone =
                        unitPriceSuspect || highSuspect
                          ? "text-red-600"
                          : diffPct == null
                            ? "text-neutral-500"
                            : Math.abs(diffPct) <= 5
                              ? "text-neutral-600"
                              : diffPct < 0
                                ? "text-emerald-700"
                                : "text-amber-700";
                      const badge =
                        diffPct == null
                          ? "· no 90d history"
                          : Math.abs(diffPct) <= 5
                            ? `≈ on par with 90d avg (${hist!.avg.toFixed(2)})`
                            : diffPct < 0
                              ? `▼ ${Math.abs(diffPct).toFixed(0)}% below 90d avg (${hist!.avg.toFixed(2)})`
                              : `▲ ${diffPct.toFixed(0)}% above 90d avg (${hist!.avg.toFixed(2)})`;
                      // PRD-003 §12 gift/bonus, now annotation only: the typed
                      // bill total is already the cash for the billed units.
                      const free = Math.min(
                        Math.max(0, freeUnits[line.po_line_id] ?? 0),
                        batchTotal,
                      );
                      const billed = batchTotal - free;

                      return (
                        <>
                          <p className={`mt-1 text-xs font-medium ${tone}`}>
                            = {unit.toFixed(2)} /unit ({total.toFixed(2)} ÷{" "}
                            {batchTotal}) {badge}
                          </p>
                          {free > 0 && (
                            <p className="mt-1 rounded bg-sky-50 px-2 py-1 text-xs text-sky-800 dark:bg-sky-900/30 dark:text-sky-300">
                              {batchTotal} units received, {billed} billed. The{" "}
                              {total.toFixed(2)} AED you typed is the cash, and
                              the {unit.toFixed(4)} AED unit cost spreads it
                              over everything that landed - the free units
                              dilute cost, they are never free stock at full
                              price.
                            </p>
                          )}
                          {unitPriceSuspect && (
                            <p className="mt-1 rounded bg-red-50 px-2 py-1 text-xs font-medium text-red-700 dark:bg-red-900/30 dark:text-red-400">
                              ⚠ {total.toFixed(2)} across {batchTotal} units is
                              only {unit.toFixed(2)} each, under a third of the
                              90-day average ({hist!.avg.toFixed(2)}). Is this
                              the UNIT price rather than the line total? Enter
                              the total for all {batchTotal} units.
                            </p>
                          )}
                          {highSuspect && (
                            <p className="mt-1 rounded bg-red-50 px-2 py-1 text-xs font-medium text-red-700 dark:bg-red-900/30 dark:text-red-400">
                              ⚠ {unit.toFixed(2)} per unit is more than 3× the
                              90-day average ({hist!.avg.toFixed(2)}). Check the
                              total and the received quantity.
                            </p>
                          )}
                        </>
                      );
                    })()}

                    {/* PRD-022: an empty or zero total must be asserted, never
                        assumed. Without this tick the line still saves - the
                        warehouse is never blocked - but it lands as 'unpriced'
                        and carries an advisory UNPRICED_RECEIPT flag. */}
                    <label className="mt-2 flex items-start gap-2 rounded border border-neutral-200 px-2 py-1.5 text-xs text-neutral-600 dark:border-neutral-700 dark:text-neutral-300">
                      <input
                        type="checkbox"
                        checked={freeGoodsLines.has(line.po_line_id)}
                        onChange={(e) => {
                          setFreeGoodsLines((prev) => {
                            const next = new Set(prev);
                            if (e.target.checked) next.add(line.po_line_id);
                            else next.delete(line.po_line_id);
                            return next;
                          });
                          if (e.target.checked) {
                            setEditedTotals((prev) => ({
                              ...prev,
                              [line.po_line_id]: 0,
                            }));
                          }
                        }}
                        className="mt-0.5"
                      />
                      <span>
                        <span className="font-medium">
                          Free goods — 0.00 is correct
                        </span>
                        <br />
                        Tick this only if the supplier delivered this line at no
                        charge.
                      </span>
                    </label>

                    {/* PRD-003 §12 - free / bonus units. Advisory and optional:
                        left empty (the normal case) nothing changes at all. */}
                    <div className="mt-2">
                      <label className="mb-0.5 block text-xs text-neutral-500">
                        Free / bonus units - delivered but not billed
                      </label>
                      <input
                        type="number"
                        min={0}
                        max={batchTotal}
                        step="1"
                        value={freeUnits[line.po_line_id] ?? ""}
                        onChange={(e) =>
                          setFreeUnits((prev) => ({
                            ...prev,
                            [line.po_line_id]:
                              e.target.value === ""
                                ? null
                                : parseFloat(e.target.value),
                          }))
                        }
                        placeholder="0"
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                      />
                    </div>
                  </div>
                </> /* end isNotPurchased ? ... : <> </> */
              )}
            </li>
          );
        })}
      </ul>

      {/* Field additions — B-4: now included in confirm flow */}
      {pendingAdditions.length > 0 && (
        <div className="mt-4 space-y-2">
          <p className="text-xs font-semibold uppercase tracking-wide text-amber-600">
            Field Additions — will be received with this PO
          </p>
          {pendingAdditions.map((a) => (
            <div
              key={a.addition_id}
              className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-3"
            >
              <div className="flex items-center justify-between mb-2">
                <div>
                  <span className="text-sm font-medium text-amber-900">
                    {a.boonz_products.boonz_product_name}
                  </span>
                  <span className="ml-2 text-xs text-amber-600">x{a.qty}</span>
                  {/* PRD-022: lead with the total (the cash), unit derived. */}
                  {a.pricing_status === "free_goods" ? (
                    <span className="ml-2 rounded bg-emerald-200 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-800">
                      free goods
                    </span>
                  ) : (
                    a.total_price_aed != null && (
                      <span className="ml-2 text-xs text-amber-600">
                        {a.total_price_aed.toFixed(2)} AED total
                        {a.price_per_unit_aed != null &&
                          ` · ${a.price_per_unit_aed.toFixed(2)}/unit`}
                      </span>
                    )
                  )}
                </div>
                <span className="rounded-full bg-amber-200 px-2 py-0.5 text-xs font-semibold text-amber-800">
                  Will receive ✓
                </span>
              </div>
              {/* WH location for the addition */}
              <input
                type="text"
                value={additionLocations[a.addition_id] ?? ""}
                onChange={(e) =>
                  setAdditionLocations((prev) => ({
                    ...prev,
                    [a.addition_id]: e.target.value,
                  }))
                }
                placeholder="Warehouse location (optional)"
                className="w-full rounded border border-amber-300 bg-white px-2 py-1.5 text-xs placeholder:text-neutral-400"
              />
            </div>
          ))}
        </div>
      )}

      {/* Already-received additions (read-only) */}
      {additions.filter((a) => a.status === "received").length > 0 && (
        <div className="mt-4 space-y-1">
          <p className="text-xs font-semibold uppercase tracking-wide text-green-700">
            Field Additions — already received
          </p>
          {additions
            .filter((a) => a.status === "received")
            .map((a) => (
              <div
                key={a.addition_id}
                className="flex items-center justify-between rounded-lg border border-green-200 bg-green-50 px-3 py-2 opacity-60"
              >
                <span className="text-xs text-green-800">
                  {a.boonz_products.boonz_product_name} x{a.qty}
                </span>
                <span className="text-xs font-medium text-green-700">
                  Received ✓
                </span>
              </div>
            ))}
        </div>
      )}

      {/* Add item button */}
      <button
        onClick={() => {
          setShowAddItem(true);
          setSelectedProduct(null);
          setAddSearch("");
          setAddBatches([{ qty: 1, expiry: "" }]);
          setAddTotal(0);
          setAddFreeGoods(false);
          setAddError(null);
        }}
        className="mt-4 w-full rounded-lg border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
      >
        + Add item not on PO
      </button>

      {/* Bottom sheet — add item */}
      {showAddItem && (
        <div className="fixed inset-0 z-50 flex items-end">
          <div
            className="absolute inset-0 bg-black/25"
            onClick={() => setShowAddItem(false)}
          />
          <div className="relative z-10 w-full rounded-t-2xl bg-white p-4 shadow-lg">
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-base font-bold">Add Item</h3>
              <button
                onClick={() => setShowAddItem(false)}
                className="text-lg text-neutral-400"
              >
                ✕
              </button>
            </div>

            {!selectedProduct ? (
              <>
                <input
                  type="text"
                  placeholder="Search products…"
                  value={addSearch}
                  onChange={(e) => setAddSearch(e.target.value)}
                  className="mb-2 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm outline-none"
                  autoFocus
                />
                <div className="max-h-60 overflow-y-auto">
                  {allProducts
                    .filter((p) =>
                      p.boonz_product_name
                        .toLowerCase()
                        .includes(addSearch.toLowerCase()),
                    )
                    .map((p) => (
                      <button
                        key={p.product_id}
                        onClick={() => setSelectedProduct(p)}
                        className="flex w-full items-center justify-between border-b border-neutral-100 px-2 py-2.5 text-left text-sm hover:bg-neutral-50"
                      >
                        <span>{p.boonz_product_name}</span>
                        {p.physical_type && (
                          <span className="ml-2 rounded bg-neutral-200 px-1.5 py-0.5 text-xs text-neutral-600">
                            {p.physical_type}
                          </span>
                        )}
                      </button>
                    ))}
                </div>
              </>
            ) : (
              <>
                <p className="mb-3 text-sm font-medium text-neutral-700">
                  {selectedProduct.boonz_product_name}
                </p>
                {/* PRD-022: the bill total for this product, not a unit price.
                    Split across batches by quantity when there is more than
                    one, so the po_additions rows sum back to what was billed. */}
                <div className="mb-3">
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Total price ex-VAT (AED) - as printed on the bill
                  </label>
                  <input
                    type="number"
                    min={0}
                    step={0.01}
                    disabled={addFreeGoods}
                    value={addFreeGoods ? "" : addTotal || ""}
                    onChange={(e) => setAddTotal(Number(e.target.value))}
                    placeholder="0.00"
                    className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm disabled:bg-neutral-100 disabled:text-neutral-400"
                  />
                  {(() => {
                    const q = addBatches.reduce(
                      (s, b) => s + (Number(b.qty) || 0),
                      0,
                    );
                    if (addFreeGoods)
                      return (
                        <p className="mt-1 rounded bg-emerald-50 px-2 py-1 text-xs text-emerald-800">
                          Free goods — stored at 0.00, never price-flagged.
                        </p>
                      );
                    const u = addTotal > 0 ? derivedUnitAed(addTotal, q) : null;
                    return u == null ? (
                      <p className="mt-1 text-xs text-neutral-400">
                        Enter the bill total, or tick “Free goods” below.
                      </p>
                    ) : (
                      <p className="mt-1 text-xs font-medium text-neutral-600">
                        = {u.toFixed(2)} /unit ({addTotal.toFixed(2)} ÷ {q})
                      </p>
                    );
                  })()}
                  <label className="mt-2 flex items-start gap-2 rounded border border-neutral-200 px-2 py-1.5 text-xs text-neutral-600">
                    <input
                      type="checkbox"
                      checked={addFreeGoods}
                      onChange={(e) => {
                        setAddFreeGoods(e.target.checked);
                        if (e.target.checked) setAddTotal(0);
                      }}
                      className="mt-0.5"
                    />
                    <span>
                      <span className="font-medium">
                        Free goods — 0.00 is correct
                      </span>
                      <br />
                      Tick only if the supplier gave this at no charge.
                    </span>
                  </label>
                  {addError && (
                    <p className="mt-2 rounded bg-red-50 px-2 py-1 text-xs font-medium text-red-700">
                      {addError}
                    </p>
                  )}
                </div>

                {/* PRD-002: one row per {qty, expiry} batch. Each becomes one
                    po_additions row. At least one batch must have an expiry. */}
                <div className="mb-3">
                  <label className="mb-1 block text-xs text-neutral-500">
                    Batches
                  </label>
                  {addBatches.map((b, idx) => (
                    <div key={idx} className="mb-2 flex items-end gap-2">
                      <div className="w-20 shrink-0">
                        <span className="block text-[10px] text-neutral-400">
                          Qty
                        </span>
                        <input
                          type="number"
                          min={1}
                          value={b.qty}
                          onChange={(e) => {
                            const v = Number(e.target.value) || 0;
                            setAddBatches((prev) =>
                              prev.map((p, i) =>
                                i === idx ? { ...p, qty: v } : p,
                              ),
                            );
                          }}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm"
                        />
                      </div>
                      <div className="min-w-0 flex-1">
                        <span className="block text-[10px] text-neutral-400">
                          Expiry (optional but recommended)
                        </span>
                        <input
                          type="date"
                          value={b.expiry}
                          onChange={(e) => {
                            const v = e.target.value;
                            setAddBatches((prev) =>
                              prev.map((p, i) =>
                                i === idx ? { ...p, expiry: v } : p,
                              ),
                            );
                          }}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm"
                        />
                      </div>
                      {addBatches.length > 1 && (
                        <button
                          type="button"
                          aria-label="Remove batch"
                          onClick={() =>
                            setAddBatches((prev) =>
                              prev.filter((_, i) => i !== idx),
                            )
                          }
                          className="shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs text-neutral-500 hover:bg-neutral-50"
                        >
                          ✕
                        </button>
                      )}
                    </div>
                  ))}
                  <button
                    type="button"
                    onClick={() =>
                      setAddBatches((prev) => [...prev, { qty: 1, expiry: "" }])
                    }
                    className="mt-1 text-xs font-medium text-blue-600 hover:text-blue-800"
                  >
                    + Add another expiry batch
                  </button>
                </div>

                <div className="flex gap-2">
                  <button
                    onClick={() => {
                      setSelectedProduct(null);
                      setAddBatches([{ qty: 1, expiry: "" }]);
                    }}
                    className="flex-1 rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600"
                  >
                    Back
                  </button>
                  <button
                    onClick={handleAddConfirm}
                    disabled={addSaving}
                    className="flex-1 rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white disabled:opacity-50"
                  >
                    {addSaving ? "Saving…" : "Confirm"}
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* Toast */}
      {toast && (
        <div className="fixed left-1/2 top-8 z-50 -translate-x-1/2 rounded-lg bg-green-600 px-4 py-2 text-sm font-medium text-white shadow-lg">
          {toast}
        </div>
      )}

      {error && (
        <p className="mt-4 text-sm text-red-600 dark:text-red-400">{error}</p>
      )}

      {/* ── PRD-003 Invoice Totals ────────────────────────────────────────────
          Everything here is DISPLAY arithmetic. set_po_document_totals
          recomputes the subtotal server-side from the non-cancelled lines and
          the unmirrored additions and never trusts a client figure - these
          numbers exist so the operator can see the document reconcile before
          they hit Confirm. */}
      {(hasActionableLines || pendingAdditions.length > 0) &&
        (() => {
          const linesSubtotal = lines.reduce((sum, l) => {
            if (notPurchasedLines.has(l.po_line_id)) return sum;
            const qty = (l.batches ?? []).reduce(
              (s, b) => s + (Number(b.received_qty) || 0),
              0,
            );
            // PRD-022: the typed bill total IS the line total. Free goods
            // contribute nothing. Same figure the submit path sends, so what
            // the operator reconciles here is what the RPC will store.
            if (freeGoodsLines.has(l.po_line_id)) return sum;
            if (qty <= 0) return sum;
            const typed = editedTotals[l.po_line_id];
            return sum + (typed != null ? typed : (l.total_price_aed ?? 0));
          }, 0);
          const additionsSubtotal = pendingAdditions.reduce(
            (s, a) => s + (a.total_price_aed ?? 0),
            0,
          );
          const r2 = (n: number) => Math.round(n * 100) / 100;
          const subtotal = r2(linesSubtotal + additionsSubtotal);
          const discount = discountAed ?? 0;
          const vatAuto = r2((subtotal - discount) * 0.05);
          const vat = vatEdited ? (vatAed ?? 0) : vatAuto;
          const other = otherAdjAed ?? 0;
          const grand = r2(subtotal - discount + vat + other);
          const variance =
            invoiceTotal != null ? r2(grand - invoiceTotal) : null;

          const inputCls =
            "w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900";

          return (
            <div className="mt-6 rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
              <h2 className="mb-3 text-sm font-semibold">Invoice Totals</h2>

              <div className="flex items-center justify-between py-1 text-sm">
                <span className="text-neutral-500">Subtotal (ex-VAT)</span>
                <span className="font-medium">{subtotal.toFixed(2)} AED</span>
              </div>
              {additionsSubtotal > 0 && (
                <p className="mb-2 text-xs text-neutral-400">
                  includes {additionsSubtotal.toFixed(2)} from{" "}
                  {pendingAdditions.length} field addition
                  {pendingAdditions.length === 1 ? "" : "s"}
                </p>
              )}

              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Discount (AED)
                  </label>
                  <input
                    type="number"
                    min={0}
                    step="0.01"
                    value={discountAed ?? ""}
                    onChange={(e) =>
                      setDiscountAed(
                        e.target.value === ""
                          ? null
                          : parseFloat(e.target.value),
                      )
                    }
                    placeholder="0.00"
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Discount label{discount > 0 ? " *" : ""}
                  </label>
                  <input
                    type="text"
                    value={discountLabel}
                    onChange={(e) => setDiscountLabel(e.target.value)}
                    placeholder="e.g. Promo"
                    className={inputCls}
                  />
                </div>
              </div>
              {discount > 0 && !discountLabel.trim() && (
                <p className="mt-1 text-xs text-red-600">
                  A discount needs a label - an unexplained adjustment is how
                  reconciliation rots.
                </p>
              )}

              <div className="mt-3">
                <label className="mb-0.5 flex items-center gap-1.5 text-xs text-neutral-500">
                  VAT @ 5% (AED)
                  <span
                    className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${
                      vatEdited
                        ? "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-400"
                        : "bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400"
                    }`}
                  >
                    {vatEdited ? "edited" : "auto"}
                  </span>
                </label>
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={vatEdited ? (vatAed ?? "") : vatAuto}
                  onChange={(e) => {
                    setVatEdited(true);
                    setVatAed(
                      e.target.value === "" ? null : parseFloat(e.target.value),
                    );
                  }}
                  className={inputCls}
                />
                {vatEdited && (
                  <button
                    type="button"
                    onClick={() => {
                      setVatEdited(false);
                      setVatAed(null);
                    }}
                    className="mt-1 text-xs text-neutral-500 underline"
                  >
                    reset to auto ({vatAuto.toFixed(2)})
                  </button>
                )}
              </div>

              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Other adjustment (AED)
                  </label>
                  <input
                    type="number"
                    step="0.01"
                    value={otherAdjAed ?? ""}
                    onChange={(e) =>
                      setOtherAdjAed(
                        e.target.value === ""
                          ? null
                          : parseFloat(e.target.value),
                      )
                    }
                    placeholder="0.00 (− for a credit)"
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Adjustment label{other !== 0 ? " *" : ""}
                  </label>
                  <input
                    type="text"
                    value={otherAdjLabel}
                    onChange={(e) => setOtherAdjLabel(e.target.value)}
                    placeholder="e.g. Delivery"
                    className={inputCls}
                  />
                </div>
              </div>
              {other !== 0 && !otherAdjLabel.trim() && (
                <p className="mt-1 text-xs text-red-600">
                  An adjustment needs a label.
                </p>
              )}

              <div className="mt-4 flex items-center justify-between border-t border-neutral-200 pt-3 dark:border-neutral-800">
                <span className="text-sm font-semibold">Grand Total</span>
                <span className="text-base font-bold">
                  {grand.toFixed(2)} AED
                </span>
              </div>

              <div className="mt-4 grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Supplier invoice no.
                  </label>
                  <input
                    type="text"
                    value={invoiceNumber}
                    onChange={(e) => setInvoiceNumber(e.target.value)}
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className="mb-0.5 block text-xs text-neutral-500">
                    Invoice date
                  </label>
                  <input
                    type="date"
                    value={invoiceDate}
                    onChange={(e) => setInvoiceDate(e.target.value)}
                    className={inputCls}
                  />
                </div>
              </div>

              <div className="mt-3">
                <label className="mb-0.5 block text-xs text-neutral-500">
                  Supplier invoice total (AED)
                </label>
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={invoiceTotal ?? ""}
                  onChange={(e) =>
                    setInvoiceTotal(
                      e.target.value === "" ? null : parseFloat(e.target.value),
                    )
                  }
                  placeholder="what the paper says"
                  className={inputCls}
                />
              </div>

              {/* Variance chip. PRD-003 CS ruling Q2: ADVISORY AT EVERY ROLE
                  LEVEL. It never blocks Confirm - receiving must not be gated
                  on a paperwork mismatch. */}
              {variance !== null && (
                <div
                  className={`mt-3 rounded px-3 py-2 text-xs font-medium ${
                    variance === 0
                      ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400"
                      : Math.abs(variance) <= 0.1
                        ? "bg-amber-50 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400"
                        : "bg-red-50 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                  }`}
                >
                  {/* §12: a variance ABOVE the paper usually means unbilled
                      free units, and the repair is to mark them as bonus - not
                      to net the gap out with an adjustment, which would leave
                      phantom cost sitting on the ex-VAT line prices that feed
                      COGS and every partner settlement. */}
                  {variance === 0
                    ? "✓ matches the supplier invoice"
                    : Math.abs(variance) <= 0.1
                      ? `≈ ${variance > 0 ? "+" : ""}${variance.toFixed(2)} AED - rounding`
                      : variance > 0
                        ? `⚠ +${variance.toFixed(2)} AED above the invoice - check the unit prices, or mark unbilled units as free/bonus on the line. Never raise a line price to match the paper.`
                        : `⚠ ${variance.toFixed(2)} AED below the invoice - check the unit prices, or add a labelled adjustment (delivery, handling).`}
                  <span className="ml-1 font-normal opacity-70">
                    (advisory - never blocks Confirm)
                  </span>
                </div>
              )}

              {totalsError && (
                <div className="mt-3 rounded bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-400">
                  {totalsError}
                  <button
                    type="button"
                    onClick={() => void saveDocumentTotals()}
                    disabled={totalsSaving}
                    className="ml-2 underline disabled:opacity-50"
                  >
                    {totalsSaving ? "Retrying…" : "Retry totals"}
                  </button>
                </div>
              )}
            </div>
          );
        })()}

      {/* Confirm button — visible when there's something to act on */}
      {(hasActionableLines || pendingAdditions.length > 0) && (
        <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
          <button
            onClick={handleConfirm}
            disabled={submitting}
            className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            {submitting ? "Confirming…" : "Confirm receiving"}
          </button>
        </div>
      )}
    </div>
  );
}
