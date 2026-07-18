# Reconciliation audit — 14/07 & 15/07 refills "are they 100% logged?"

**Run:** 2026-07-16 · **Source:** driver doc (14–16 Jul) vs live `refill_plan_output` (the log) + live `pod_inventory`.
**Verdict:** NOT logged. What IS in `refill_plan_output` for 14/07 is the **engine plan** (Aquafina, M&M,
Barebells, VW Antioxidant/Reload), not the manual refill the team recorded. And `pod_inventory` only
partially matches the doc. So three sources disagree. Nothing here should be blind-written.

Legend: ✅ consistent · 📝 in pod but not logged (log-only gap) · ⚠️ pod ≠ doc (needs a call) · ➡️ transfer.

---

## Cross-cutting decisions (answer these first — they unblock everything)

1. **Nutella expiry — 25/11 vs 26/11.** The 14/07 Carrefour buy is written **26/11/26** (30 pcs, "refilled
   all"). But the machines/WH currently hold Nutella at **25/11/26** and **16/09/26**. Is the Carrefour
   Nutella a genuinely **new 26/11 batch**, or the same 25/11 batch mis-dated? (Decides merge vs add.)
2. **Ground truth = the doc?** Confirm I should **SET each shelf to the doc's physical numbers** (and
   decrement/return WH + write one log row per line), rather than adding deltas on top of current pod.
3. **Ritz 24 @ 17/04/27 → WH_CENTRAL return** — create that warehouse credit? (Carrefour buy, not machine.)
4. **VW Zero Lemon header says 24 "refilled all"** but only ~16 land in machines below (0797:6 + 0736:10).
   Where do the other ~8 go — WH_MCC, or is a machine line missing?

---

## 14/07

### VOXMCC-1011 (0795)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 7 Nutella 26/11 | no | 4 @ 25/11 (A16) | ⚠️ qty & expiry differ |
| 3 dates ball coconut | no | none on machine | ⚠️ not in pod; which shelf? |
| 2 dates ball sesame | no | Sesame 7 @ 02/02 (A03) | ⚠️ |
| 7 Tamreem Yellow Peach ➡️ from 0817 | no | Peach 3 @ 12/03 (A15) | ⚠️ transfer unlogged, qty differs |
| 8 VW Zero Peach 06/09 | no | none (A10 has Antiox/Care/Upgrade/ZeroLemon) | ⚠️ not in pod |

### VOXMCC-1005 (0797)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 11 Nutella 26/11 ("fix expiry") | no | **17 @ 16/09** (A15) | ⚠️ big expiry mismatch |
| 6 VW Zero Lemon 06/09 | log shows 3 | 6 @ 06/09 (A16) | 📝 pod ok, log says 3 |

### ACTIVATEMCC-1037 (0736)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 15 Evian regular | log shows Evian330 18 / Evian1L 5 | 330ML 17, 1L 15 | ⚠️ which "regular"? |
| 10 VW Lemon 06/09 | no | **no Zero Lemon on machine** | ⚠️ not in pod |
| 4 Nutella 26/11 | no | 6 @ 25/11 (A13) | ⚠️ qty & expiry differ |

### ACTIVATE-2005 (0817)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 4 Gatorade Fruit Punch | log shows Gatorade 3+2 | FP 8 @ 14/02 (A06) | ⚠️ (FP already reconciled 10/07) |
| 7 Tamreem Peach ➡️ to 0795 | no | only Mango 8 (B02), no Peach | ⚠️ product mismatch (Mango vs Peach?) |
| 8 Nutella 26/11 ("fix expiry") | log shows 10 | 11 @ 16/09 (B08) | ⚠️ expiry differs |

### OMDBB (0809) ➡️ OMDCW (0811) — Plaay transfer
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 6 Plaay tablet removed (0809) | **✅ logged** Remove 6 (A05) | Dark Choc 4 (A05) | ✅ out-leg logged |
| 6 Plaay received (0811) | log shows Refill **3** | Milk Toffee 3 (A07) | ⚠️ in-leg logged as 3, not 6 |

---

## 15/07

### AMZ-1057 (0716) ➡️ ALJLT-1015 (0800)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 5 VW Antioxidant 27/09 ➡️ to 0800 | no | 0716 has Antiox 1 @ 30/08; 0800 has none | ⚠️ transfer unlogged, batch 27/09 not in either pod |

### NOOK (0808) ➡️ ALJ-1014 O1 (0799)
| Doc line | Logged? | Pod now | Status |
|---|---|---|---|
| 1 Plaay Dark Choc 50g removed (0808) ➡️ to 0799 | no | 0808 has Dark Choc 1 @ 05/11 (A06); 0799 has none | ⚠️ transfer unlogged (FE approve error blocked it) |

### ALJLT-1015 (0800)
- Engine-refill dispatching error only (driver removed 2 of each flavour) — FE bug, no data line to log,
  except it is the **destination** of the 0716 VW Antioxidant transfer above.

---

## 16/07
Recommendations only (next-visit requests). **Nothing physical to log.**

---

## What I can do on your go
- Log the clean/agreed lines as the full chain (pod SET + WH decrement/return + one `refill_plan_output`
  row each), machine by machine, once you confirm decisions 1–4.
- The two half-logged transfers (OMDBB→OMDCW Plaay; and the two unlogged 15/07 transfers) I'll complete as
  balanced two-leg moves.
- I will not touch the FE-bug items (Nissan WH_MCC/Central packing, 0800 dispatch qty, Nook approve error) —
  those are the flow bugs, logged separately.
