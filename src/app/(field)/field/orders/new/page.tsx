'use client'

// Note: RESEND_API_KEY must be set in Supabase Edge Function secrets
// Supabase dashboard → Edge Functions → send-po-notification → Secrets

import { useEffect, useState, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'
import * as XLSX from 'xlsx'

const WALK_IN_SUPPLIER_CODES = ['SUP_005', 'SUP_011'] as const
const EDGE_FN_URL =
  'https://eizcexopcuoycuosittm.supabase.co/functions/v1/send-po-notification'

interface Supplier {
  supplier_id: string
  supplier_name: string
  supplier_code: string | null
  contact_email: string | null
}

interface Product {
  product_id: string
  boonz_product_name: string
  product_category: string | null
}

interface POLine {
  key: string
  product_id: string
  product_name: string
  qty: number
  price: number | null
}

interface ImportedRow {
  key: string
  raw_name: string
  matched_product: Product | null
  qty: number
  price: number | null
  expiry_date: string
  error: boolean
}

type EntryMode = 'manual' | 'import'

function generateKey(): string {
  return Math.random().toString(36).slice(2, 10)
}

function fuzzyMatch(query: string, products: Product[]): Product | null {
  const q = query.toLowerCase().trim()
  if (!q) return null
  const exact = products.find(
    (p) => p.boonz_product_name.toLowerCase() === q
  )
  if (exact) return exact
  const starts = products.find(
    (p) => p.boonz_product_name.toLowerCase().startsWith(q)
  )
  if (starts) return starts
  const contains = products.find(
    (p) => p.boonz_product_name.toLowerCase().includes(q)
  )
  if (contains) return contains
  return null
}

function SearchableDropdown<T extends { id: string; label: string; secondary?: string }>({
  items,
  value,
  onChange,
  placeholder,
}: {
  items: T[]
  value: string
  onChange: (id: string) => void
  placeholder: string
}) {
  const [search, setSearch] = useState('')
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  const selected = items.find((i) => i.id === value)

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [])

  const filtered = search.trim()
    ? items.filter(
        (i) =>
          i.label.toLowerCase().includes(search.toLowerCase()) ||
          (i.secondary && i.secondary.toLowerCase().includes(search.toLowerCase()))
      )
    : items

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => { setOpen(!open); setSearch('') }}
        className="w-full rounded border border-neutral-300 px-3 py-2 text-left text-sm dark:border-neutral-600 dark:bg-neutral-900"
      >
        {selected ? (
          <span>
            {selected.label}
            {selected.secondary && (
              <span className="ml-1 text-neutral-400">{selected.secondary}</span>
            )}
          </span>
        ) : (
          <span className="text-neutral-400">{placeholder}</span>
        )}
      </button>
      {open && (
        <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-48 overflow-auto rounded-lg border border-neutral-200 bg-white shadow-lg dark:border-neutral-700 dark:bg-neutral-900">
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Type to search…"
            autoFocus
            className="w-full border-b border-neutral-200 px-3 py-2 text-sm outline-none dark:border-neutral-700 dark:bg-neutral-900"
          />
          {filtered.length === 0 ? (
            <p className="px-3 py-2 text-xs text-neutral-400">No results</p>
          ) : (
            filtered.map((item) => (
              <button
                key={item.id}
                type="button"
                onClick={() => {
                  onChange(item.id)
                  setOpen(false)
                  setSearch('')
                }}
                className="flex w-full items-baseline gap-2 px-3 py-2 text-left text-sm hover:bg-neutral-100 dark:hover:bg-neutral-800"
              >
                <span className="truncate">{item.label}</span>
                {item.secondary && (
                  <span className="shrink-0 text-xs text-neutral-400">{item.secondary}</span>
                )}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  )
}

export default function NewOrderPage() {
  const router = useRouter()

  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [products, setProducts] = useState<Product[]>([])
  const [loading, setLoading] = useState(true)

  // Header
  const [supplierId, setSupplierId] = useState('')
  const [poDate, setPoDate] = useState(() => new Date().toISOString().split('T')[0])
  const [poId, setPoId] = useState('')

  // Mode
  const [mode, setMode] = useState<EntryMode>('manual')

  // Manual lines
  const [lines, setLines] = useState<POLine[]>([
    { key: crypto.randomUUID(), product_id: '', product_name: '', qty: 0, price: null },
  ])

  // Import
  const [importedRows, setImportedRows] = useState<ImportedRow[]>([])
  const [importReady, setImportReady] = useState(false)

  // Price input raw strings (FIX 3: prevent decimal point loss on keystroke)
  const [priceInputs, setPriceInputs] = useState<Record<string, string>>({})
  // Last purchase price hints (FIX 2: auto-fill on product select)
  const [lastPrices, setLastPrices] = useState<Record<string, number | null>>({})

  // Submit + confirm dialog
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showConfirm, setShowConfirm] = useState(false)
  const [submitStatus, setSubmitStatus] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const { data: suppData, error: suppErr } = await supabase
      .from('suppliers')
      .select('supplier_id, supplier_name, supplier_code, contact_email')
      .eq('status', 'Active')
      .order('supplier_name')
    if (suppErr) console.error('[NewOrder] suppliers fetch error:', suppErr)
    else console.log('[NewOrder] suppliers loaded:', suppData?.length)
    if (suppData) setSuppliers(suppData)

    const { data: prodData, error: prodErr } = await supabase
      .from('boonz_products')
      .select('product_id, boonz_product_name, product_category')
      .order('boonz_product_name')
    if (prodErr) console.error('[NewOrder] products fetch error:', prodErr)
    else console.log('[NewOrder] products loaded:', prodData?.length)
    if (prodData) setProducts(prodData)

    const { data: lastPO } = await supabase
      .from('purchase_orders')
      .select('po_number')
      .not('po_number', 'is', null)
      .order('po_number', { ascending: false })
      .limit(1)
      .single()
    const nextNum = (lastPO?.po_number ?? 9016) + 1
    setPoId(`PO-${new Date().getFullYear()}-${nextNum}`)

    setLoading(false)
  }, [])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  // -- Manual entry helpers --

  function updateLine(key: string, field: keyof POLine, value: string | number | null) {
    setLines((prev) =>
      prev.map((l) => (l.key === key ? { ...l, [field]: value } : l))
    )
  }

  function addLine() {
    setLines((prev) => [
      ...prev,
      { key: crypto.randomUUID(), product_id: '', product_name: '', qty: 0, price: null },
    ])
  }

  function duplicateLastLine() {
    const last = lines[lines.length - 1]
    if (!last) return addLine()
    setLines((prev) => [
      ...prev,
      { ...last, key: generateKey() },
    ])
  }

  function removeLine(key: string) {
    setLines((prev) => {
      if (prev.length <= 1) return prev
      return prev.filter((l) => l.key !== key)
    })
  }

  function handleSupplierChange(id: string) {
    setSupplierId(id)
    setLines([{ key: crypto.randomUUID(), product_id: '', product_name: '', qty: 0, price: null }])
    setPriceInputs({})
    setLastPrices({})
  }

  async function fetchLastPrice(boonzProductId: string): Promise<number | null> {
    const supabase = createClient()
    const { data } = await supabase
      .from('purchase_orders')
      .select('price_per_unit_aed')
      .eq('boonz_product_id', boonzProductId)
      .not('price_per_unit_aed', 'is', null)
      .order('purchase_date', { ascending: false })
      .limit(1)
      .single()
    return data?.price_per_unit_aed ?? null
  }

  // -- Excel import --

  function handleFileUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return

    const reader = new FileReader()
    reader.onload = (evt) => {
      const data = evt.target?.result
      if (!data) return

      const workbook = XLSX.read(data, { type: 'array' })
      const sheet = workbook.Sheets[workbook.SheetNames[0]]
      const jsonRows = XLSX.utils.sheet_to_json<unknown[]>(sheet, { header: 1 })

      // Skip header row
      const dataRows = jsonRows.slice(1)

      const parsed: ImportedRow[] = dataRows
        .filter((row) => row && row.length > 0 && row[0])
        .map((row) => {
          const rawName = String(row[0] ?? '').trim()
          const qty = Number(row[1]) || 1
          const rawPrice = row[2] !== undefined && row[2] !== '' ? Number(row[2]) : null
          let expiryDate = ''
          if (row[3]) {
            const val = row[3]
            if (typeof val === 'number') {
              const d = XLSX.SSF.parse_date_code(val)
              expiryDate = `${d.y}-${String(d.m).padStart(2, '0')}-${String(d.d).padStart(2, '0')}`
            } else {
              const parsed = new Date(String(val))
              if (!isNaN(parsed.getTime())) {
                expiryDate = parsed.toISOString().split('T')[0]
              }
            }
          }

          const matched = fuzzyMatch(rawName, products)

          return {
            key: generateKey(),
            raw_name: rawName,
            matched_product: matched,
            qty,
            price: rawPrice,
            expiry_date: expiryDate,
            error: !matched,
          }
        })

      setImportedRows(parsed)
      setImportReady(true)
    }
    reader.readAsArrayBuffer(file)
  }

  function updateImportRow(key: string, productId: string) {
    const product = products.find((p) => p.product_id === productId)
    setImportedRows((prev) =>
      prev.map((r) =>
        r.key === key
          ? { ...r, matched_product: product ?? null, error: !product }
          : r
      )
    )
  }

  function updateImportQty(key: string, qty: number) {
    setImportedRows((prev) =>
      prev.map((r) => (r.key === key ? { ...r, qty } : r))
    )
  }

  function updateImportPrice(key: string, price: number | null) {
    setImportedRows((prev) =>
      prev.map((r) => (r.key === key ? { ...r, price } : r))
    )
  }

  // -- Resolve final lines from either mode --

  function resolveFinalLines() {
    return mode === 'manual'
      ? lines
          .filter((l) => l.product_id && l.qty > 0)
          .map((l) => ({
            product_id: l.product_id,
            product_name: products.find((p) => p.product_id === l.product_id)?.boonz_product_name ?? '',
            qty: l.qty,
            price: l.price,
            expiry_date: '' as string,
          }))
      : importedRows
          .filter((r) => r.matched_product)
          .map((r) => ({
            product_id: r.matched_product!.product_id,
            product_name: r.matched_product!.boonz_product_name,
            qty: r.qty,
            price: r.price,
            expiry_date: r.expiry_date,
          }))
  }

  // -- Step 1: Validate and show confirm dialog --

  function handleSubmit() {
    setError(null)

    if (!supplierId) {
      setError('Please select a supplier')
      return
    }

    const finalLines = resolveFinalLines()
    if (finalLines.length === 0) {
      setError('Add at least one product with qty > 0')
      return
    }

    const missingPrice = finalLines.find(l => !l.price || l.price <= 0)
    if (missingPrice) {
      setError('Unit price is required for all lines')
      return
    }

    setShowConfirm(true)
  }

  // -- Step 2: Confirm & send --

  async function handleConfirmSend() {
    setShowConfirm(false)
    setSubmitting(true)
    setSubmitStatus('Saving and sending…')
    setError(null)

    const supabase = createClient()
    const supplier = suppliers.find((s) => s.supplier_id === supplierId)
    if (!supplier) {
      setError('Supplier not found')
      setSubmitting(false)
      setSubmitStatus(null)
      return
    }

    const finalLines = resolveFinalLines()

    // Get next po_number
    const { data: lastPo } = await supabase
      .from('purchase_orders')
      .select('po_number')
      .not('po_number', 'is', null)
      .order('po_number', { ascending: false })
      .limit(1)
      .single()

    const nextNumber = (lastPo?.po_number ?? 9016) + 1

    const inserts = finalLines.map((line) => ({
      po_id: poId,
      po_number: nextNumber,
      supplier_id: supplierId,
      boonz_product_id: line.product_id,
      purchase_date: poDate,
      ordered_qty: line.qty,
      price_per_unit_aed: line.price,
      total_price_aed: line.price ? line.qty * line.price : null,
      expiry_date: line.expiry_date || null,
      received_date: null,
    }))

    // a. Insert PO lines
    const { error: insertError } = await supabase
      .from('purchase_orders')
      .insert(inserts)

    if (insertError) {
      setError(`Failed to save order — try again`)
      setSubmitting(false)
      setSubmitStatus(null)
      return
    }

    // b. Notification: driver_task (direct DB) or email (Edge Function, non-blocking)
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      setError('Session expired — please log in again')
      setSubmitting(false)
      setSubmitStatus(null)
      return
    }

    const isWalkIn = WALK_IN_SUPPLIER_CODES.includes(
      (supplier.supplier_code ?? '') as typeof WALK_IN_SUPPLIER_CODES[number]
    )

    if (isWalkIn) {
      const notes = finalLines.map((l) => `${l.product_name} x${l.qty}`).join(', ')
      const { error: taskError } = await supabase
        .from('driver_tasks')
        .insert({
          po_id: poId,
          po_number: nextNumber,
          supplier_id: supplierId,
          status: 'pending',
          created_by: user.id,
          notes,
        })
      if (taskError) {
        console.error('[NewOrder] driver_task insert error:', taskError)
        setError('Order saved but could not create driver task. Please contact admin.')
        setSubmitting(false)
        setSubmitStatus(null)
        return
      }
      await supabase.from('po_notifications').insert({
        po_id: poId,
        po_number: nextNumber,
        notification_type: 'driver_task',
        recipient: 'driver',
        status: 'sent',
        sent_by: user.id,
      })
      setSubmitStatus('Order created — driver task sent')
    } else {
      // Email: call Edge Function non-blocking (PO is already saved)
      try {
        const { data: { session } } = await supabase.auth.getSession()
        await fetch(EDGE_FN_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${session?.access_token}`,
            'apikey': process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '',
          },
          body: JSON.stringify({
            po_id: poId,
            po_number: nextNumber,
            supplier_id: supplierId,
            supplier_email: supplier.contact_email,
            notification_type: 'email',
            created_by: user.id,
            lines: finalLines.map((l) => ({
              boonz_product_name: l.product_name,
              ordered_qty: l.qty,
              price_per_unit_aed: l.price,
              total_price_aed: l.price ? l.qty * l.price : null,
              expiry_date: l.expiry_date || null,
            })),
          }),
        })
      } catch (err) {
        console.error('[NewOrder] email notification failed (non-blocking):', err)
      }
      setSubmitStatus(`Order saved and email sent to ${supplier.supplier_name}`)
    }

    // Reset form for next order
    setLines([{ key: crypto.randomUUID(), product_id: '', product_name: '', qty: 0, price: null }])
    setSupplierId('')
    setPriceInputs({})
    setLastPrices({})
    setPoId(`PO-${new Date().getFullYear()}-${nextNumber + 1}`)

    setTimeout(() => router.push('/field/orders'), 1500)
  }

  // Derived: selected supplier info for confirm dialog
  const selectedSupplier = suppliers.find((s) => s.supplier_id === supplierId)
  const isWalkIn = selectedSupplier
    ? WALK_IN_SUPPLIER_CODES.includes(
        (selectedSupplier.supplier_code ?? '') as typeof WALK_IN_SUPPLIER_CODES[number]
      )
    : false

  if (loading) {
    return (
      <>
        <FieldHeader title="New Order" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    )
  }

  const supplierItems = suppliers.map((s) => ({
    id: s.supplier_id,
    label: s.supplier_name,
    secondary: s.supplier_code ?? undefined,
  }))

  const productItems = products.map((p) => ({
    id: p.product_id,
    label: p.boonz_product_name,
    secondary: p.product_category ?? undefined,
  }))

  return (
    <div className="px-4 py-4 pb-24">
      <button
        onClick={() => router.push('/field/orders')}
        className="mb-3 text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
      >
        ← Back to orders
      </button>

      <h1 className="mb-4 text-xl font-semibold">New Purchase Order</h1>

      {/* Header fields */}
      <div className="mb-4 space-y-3 rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <div>
          <label className="block text-xs text-neutral-500 mb-0.5">
            Supplier <span className="text-red-500">*</span>
          </label>
          <SearchableDropdown
            items={supplierItems}
            value={supplierId}
            onChange={handleSupplierChange}
            placeholder="Select supplier…"
          />
        </div>

        <div className="flex gap-3">
          <div className="flex-1">
            <label className="block text-xs text-neutral-500 mb-0.5">PO Date</label>
            <input
              type="date"
              value={poDate}
              onChange={(e) => setPoDate(e.target.value)}
              className="w-full rounded border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <div className="flex-1">
            <label className="block text-xs text-neutral-500 mb-0.5">PO ID</label>
            <p className="rounded border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm text-neutral-700 dark:border-neutral-700 dark:bg-neutral-800 dark:text-neutral-300">
              {poId}
            </p>
            <p className="mt-0.5 text-xs text-neutral-400">Auto-generated</p>
          </div>
        </div>
      </div>

      {/* Mode tabs */}
      <div className="mb-4 flex border-b border-neutral-200 dark:border-neutral-800">
        {([
          { label: 'Manual entry', value: 'manual' as EntryMode },
          { label: 'Import from Excel', value: 'import' as EntryMode },
        ]).map((t) => (
          <button
            key={t.value}
            onClick={() => setMode(t.value)}
            className={`flex-1 py-2.5 text-sm font-medium transition-colors ${
              mode === t.value
                ? 'border-b-2 border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100'
                : 'text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Manual entry */}
      {mode === 'manual' && (
        <div className="space-y-3">
          {lines.map((line, idx) => (
            <div
              key={line.key}
              className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-center justify-between mb-2">
                <span className="text-xs text-neutral-400">Line {idx + 1}</span>
                {lines.length > 1 && (
                  <button
                    onClick={() => removeLine(line.key)}
                    className="text-xs text-red-500 hover:text-red-700"
                  >
                    ×  Remove
                  </button>
                )}
              </div>

              <div className="space-y-2">
                <div>
                  <label className="block text-xs text-neutral-500 mb-0.5">
                    Product <span className="text-red-500">*</span>
                  </label>
                  <SearchableDropdown
                    items={productItems}
                    value={line.product_id}
                    onChange={async (id) => {
                      updateLine(line.key, 'product_id', id)
                      const lastPrice = await fetchLastPrice(id)
                      setLastPrices((prev) => ({ ...prev, [line.key]: lastPrice }))
                      if (lastPrice !== null) {
                        updateLine(line.key, 'price', lastPrice)
                        setPriceInputs((prev) => ({ ...prev, [line.key]: String(lastPrice) }))
                      }
                    }}
                    placeholder="Select product…"
                  />
                </div>

                <div className="flex gap-2">
                  <div className="flex-1">
                    <label className="block text-xs text-neutral-500 mb-0.5">
                      Qty <span className="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      inputMode="numeric"
                      pattern="[0-9]*"
                      value={line.qty === 0 ? '' : line.qty}
                      placeholder="0"
                      onFocus={(e) => e.target.select()}
                      onChange={(e) => {
                        const val = e.target.value.replace(/[^0-9]/g, '')
                        updateLine(line.key, 'qty', val === '' ? 0 : Math.max(0, parseInt(val, 10)))
                      }}
                      className="w-full rounded border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </div>
                  <div className="flex-1">
                    <label className="block text-xs text-neutral-500 mb-0.5">
                      Unit price (AED) <span className="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={priceInputs[line.key] ?? (line.price === null ? '' : String(line.price))}
                      placeholder="0.00"
                      onFocus={(e) => e.target.select()}
                      onChange={(e) => {
                        const val = e.target.value.replace(/[^0-9.]/g, '')
                        setPriceInputs((prev) => ({ ...prev, [line.key]: val }))
                      }}
                      onBlur={() => {
                        const raw = priceInputs[line.key] ?? ''
                        const num = parseFloat(raw)
                        const parsed = isNaN(num) ? null : Math.round(num * 100) / 100
                        updateLine(line.key, 'price', parsed)
                        setPriceInputs((prev) => ({ ...prev, [line.key]: parsed === null ? '' : String(parsed) }))
                      }}
                      className="w-full rounded border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                    {lastPrices[line.key] != null && (
                      <p className="mt-0.5 text-xs text-neutral-400">
                        Last purchase: AED {lastPrices[line.key]}
                      </p>
                    )}
                  </div>
                </div>

              </div>
            </div>
          ))}

          <div className="flex gap-2">
            <button
              onClick={addLine}
              className="flex-1 rounded-lg border border-dashed border-neutral-300 py-2.5 text-sm text-neutral-500 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:hover:bg-neutral-900"
            >
              + Add product
            </button>
            <button
              onClick={duplicateLastLine}
              className="flex-1 rounded-lg border border-dashed border-neutral-300 py-2.5 text-sm text-neutral-500 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:hover:bg-neutral-900"
            >
              Duplicate last
            </button>
          </div>
        </div>
      )}

      {/* Import from Excel */}
      {mode === 'import' && (
        <div>
          {!importReady ? (
            <div className="space-y-3">
              <div className="rounded-lg border-2 border-dashed border-neutral-300 p-8 text-center dark:border-neutral-600">
                <p className="mb-2 text-sm text-neutral-600 dark:text-neutral-400">
                  Upload Excel file (.xlsx or .csv)
                </p>
                <input
                  type="file"
                  accept=".xlsx,.csv"
                  onChange={handleFileUpload}
                  className="mx-auto block text-sm text-neutral-500"
                />
              </div>
              <div className="rounded-lg bg-neutral-50 p-3 dark:bg-neutral-900">
                <p className="text-xs font-medium text-neutral-600 dark:text-neutral-400 mb-1">
                  Expected column format:
                </p>
                <div className="overflow-x-auto">
                  <table className="text-xs text-neutral-500">
                    <thead>
                      <tr>
                        <th className="pr-4 text-left font-medium">Product Name</th>
                        <th className="pr-4 text-left font-medium">Qty</th>
                        <th className="pr-4 text-left font-medium">Unit Price (AED)</th>
                        <th className="text-left font-medium">Expiry Date</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <td className="pr-4 text-neutral-400">Mars Bar 50g</td>
                        <td className="pr-4 text-neutral-400">24</td>
                        <td className="pr-4 text-neutral-400">2.50</td>
                        <td className="text-neutral-400">2026-06-15</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          ) : (
            <div className="space-y-2">
              <div className="flex items-center justify-between mb-2">
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  {importedRows.length} rows parsed
                </p>
                <button
                  onClick={() => {
                    setImportedRows([])
                    setImportReady(false)
                  }}
                  className="text-xs text-neutral-500 hover:text-neutral-700"
                >
                  Clear &amp; re-upload
                </button>
              </div>

              {importedRows.map((row) => (
                <div
                  key={row.key}
                  className={`rounded-lg border p-3 ${
                    row.error
                      ? 'border-red-300 bg-red-50 dark:border-red-800 dark:bg-red-950'
                      : 'border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950'
                  }`}
                >
                  <div className="flex items-center gap-2 mb-2">
                    <span className={`text-xs ${row.error ? 'text-red-600' : 'text-green-600'}`}>
                      {row.error ? '✗' : '✓'}
                    </span>
                    <span className="text-xs text-neutral-400 truncate">
                      &quot;{row.raw_name}&quot;
                    </span>
                  </div>

                  {row.error ? (
                    <div>
                      <p className="text-xs text-red-600 mb-1 dark:text-red-400">
                        Product not found — select manually
                      </p>
                      <SearchableDropdown
                        items={productItems}
                        value={row.matched_product?.product_id ?? ''}
                        onChange={(id) => updateImportRow(row.key, id)}
                        placeholder="Select product…"
                      />
                    </div>
                  ) : (
                    <p className="text-sm font-medium truncate">
                      {row.matched_product?.boonz_product_name}
                    </p>
                  )}

                  <div className="mt-2 flex gap-2">
                    <div className="flex-1">
                      <label className="block text-xs text-neutral-500 mb-0.5">Qty</label>
                      <input
                        type="number"
                        min={1}
                        value={row.qty}
                        onChange={(e) => updateImportQty(row.key, parseInt(e.target.value) || 1)}
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                      />
                    </div>
                    <div className="flex-1">
                      <label className="block text-xs text-neutral-500 mb-0.5">Price (AED)</label>
                      <input
                        type="number"
                        min={0}
                        step={0.01}
                        value={row.price ?? ''}
                        onChange={(e) =>
                          updateImportPrice(row.key, e.target.value ? parseFloat(e.target.value) : null)
                        }
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                      />
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Error / status */}
      {error && (
        <p className="mt-4 text-sm text-red-600 dark:text-red-400">{error}</p>
      )}
      {submitStatus && (
        <p className="mt-4 text-sm font-medium text-green-600 dark:text-green-400">{submitStatus}</p>
      )}

      {/* Submit */}
      <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <button
          onClick={handleSubmit}
          disabled={submitting}
          className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {submitting ? (submitStatus ?? 'Creating…') : 'Create PO'}
        </button>
      </div>

      {/* Confirm dialog */}
      {showConfirm && selectedSupplier && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 px-6">
          <div className="w-full max-w-sm rounded-xl bg-white p-6 shadow-xl dark:bg-neutral-900">
            <h2 className="text-lg font-semibold mb-2">
              Send order to {selectedSupplier.supplier_name}?
            </h2>

            {isWalkIn ? (
              <>
                <div className="mb-3 flex items-center gap-2">
                  <span className="text-xl">🚗</span>
                  <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800 dark:bg-blue-900 dark:text-blue-200">
                    Driver task
                  </span>
                </div>
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  This will create a task for the driver to collect this order
                  from {selectedSupplier.supplier_name}.
                </p>
              </>
            ) : (
              <>
                <div className="mb-3 flex items-center gap-2">
                  <span className="text-xl">📧</span>
                  <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                    Email
                  </span>
                </div>
                <p className="text-sm text-neutral-600 dark:text-neutral-400">
                  This will send a purchase order email to {selectedSupplier.supplier_name}{' '}
                  and CC info@boonz.me.
                </p>
                <p className="mt-1 text-xs text-neutral-400">
                  To: {selectedSupplier.contact_email || 'info@boonz.me'}
                </p>
              </>
            )}

            <div className="mt-5 flex gap-3">
              <button
                onClick={() => setShowConfirm(false)}
                className="flex-1 rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                onClick={handleConfirmSend}
                className="flex-1 rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              >
                Confirm &amp; send
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
