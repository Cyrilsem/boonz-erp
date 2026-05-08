# SOP-001 — Procurement Flow
**Boonz ERP · Last updated: 2026-04-28 · Status: Live**

---

## Overview

Procurement is the process of getting stock from suppliers into the warehouse. There are two types of suppliers: **walk-in** (driver goes to buy) and **supplier-delivered** (they come to us).

**Walk-in suppliers:** Union Coop · Carrefour · Arab Sweet · Merich
**Supplier-delivered:** Champions Food · EATCO · General Food Chocolate · others

---

## Who Does What

| Role | Responsibilities |
|---|---|
| **Operator / Manager** | Creates the PO, monitors order status |
| **Driver** | Acknowledges task, buys at store, reports outcomes per product |
| **Warehouse** | Receives goods, enters quantities + expiry dates, confirms stock |
| **System** | Routes notifications, updates status, logs every event automatically |

---

## Step-by-Step Flow

### Phase 1 — Create the Purchase Order

**Who:** Operator or Manager
**Where:** `/field/orders/new`

1. Open the field app → **Orders** → tap **+** (bottom right)
2. Select the supplier from the dropdown
3. The app automatically shows:
   - 🚗 **Walk-in** badge → a driver task will be created
   - 📧 **Supplier delivery** badge → a PO email will be sent to the supplier
4. Add each product and quantity
5. Tap **Create PO** → confirm in the dialog
6. The PO number is assigned automatically (no duplicates possible)

> **Emergency:** If you need the driver to collect from a normally-delivered supplier, tick the **🚨 Emergency: assign driver task to go collect** checkbox before confirming.

---

### Phase 2 — Driver Collection *(Walk-in suppliers only)*

**Who:** Driver
**Where:** `/field/tasks`

1. Open the field app → **Tasks**
2. Find the new task (supplier name + PO number shown)
3. Tap **Acknowledge** before leaving — status changes to *On my way*
4. Go to the store and purchase the items
5. Tap the task to expand it — for each product, select the outcome:
   - ✅ **Full** — bought everything
   - ⚠️ **Partial** — enter how many units you got
   - ❌ **Not available** — item was out of stock
   - 📝 **Other** — add a note
6. Once ALL products have an outcome, tap **Mark as collected**

> The order list will now show **📦 In transit — awaiting WH receipt** so the operator knows goods are coming.

---

### Phase 3 — Warehouse Receipt

**Who:** Warehouse
**Where:** `/field/orders` → tap pending PO → tap **Receive**

1. Open **Orders** → **Pending** tab → find the PO
2. Tap **Receive** — the receiving screen opens
3. The **driver's field report** is shown per product as a hint (what they bought)
4. For each product line:
   - Enter **received quantity**
   - Enter **expiry date** (add multiple batches if different expiry dates)
   - Enter **warehouse location** (e.g. A-01)
   - Adjust **price per unit** if different from the order

5. **If an item was NOT purchased:**
   - Tap **Mark not purchased** (top-right of the product card)
   - Card turns red — no stock will be added
   - Lines the driver reported as "not available" are pre-toggled automatically

6. Tap **Confirm receiving**
   - All received items are added to warehouse stock immediately
   - Any field additions (items added beyond the original PO) are also inventoried
   - The PO is closed

---

## Key Rules

- **One PO per purchase run** — don't create multiple POs for the same trip
- **Always acknowledge the task** before leaving — the operator needs to see you're on the way
- **Always fill all outcomes** before marking collected — the button won't activate otherwise
- **Mark not purchased clearly** — don't leave items as pending. A line left open blocks the PO from closing
- **Expiry dates are mandatory** for food items — enter them even if it's a single batch

---

## What Gets Logged Automatically

Every action creates an audit trail entry:

| Event | When |
|---|---|
| `po_created` | PO is submitted |
| `task_assigned` | Driver task is created |
| `task_acknowledged` | Driver taps Acknowledge |
| `task_collected` | Driver marks as collected |
| `goods_received` | WH confirms receipt |
| `line_not_purchased` | WH marks a line as not purchased |

---

## Data Outcomes

| Field | Value | Meaning |
|---|---|---|
| `purchase_outcome` | `received` | Stock added to warehouse |
| `purchase_outcome` | `not_purchased` | Line closed, no stock added |
| `purchase_outcome` | `null` | Still pending |
| `received_qty` | > 0 | Units added to WH batch |
| `received_qty` | 0 | Not purchased |

---

## Supplier Reference

| Supplier | Code | Type | Driver Task? |
|---|---|---|---|
| Union Coop | SUP_005 | walk_in | ✅ Always |
| Carrefour | SUP_011 | walk_in | ✅ Always |
| Arab Sweet | SUP_007 | walk_in | ✅ Always |
| Merich Global | SUP_001 | walk_in | ✅ Always |
| Champions Food | SUP_003 | supplier_delivered | ❌ Unless emergency |
| EATCO | SUP_002 | supplier_delivered | ❌ Unless emergency |
| General Food Chocolate | SUP_004 | supplier_delivered | ❌ Unless emergency |

---

*SOP-001 · Boonz ERP · Procurement · 2026-04-28*
