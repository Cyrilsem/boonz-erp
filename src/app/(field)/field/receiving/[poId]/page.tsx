'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

interface POLine {
  po_line_id: string
  boonz_product_id: string
  boonz_product_name: string
  ordered_qty: number
  received_qty: number
  expiry_date: string
  wh_location: string
  overage: boolean
}

interface POHeader {
  po_id: string
  supplier_name: string
  purchase_date: string
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

export default function ReceivingDetailPage() {
  const params = useParams<{ poId: string }>()
  const router = useRouter()
  const poId = decodeURIComponent(params.poId)

  const [header, setHeader] = useState<POHeader | null>(null)
  const [lines, setLines] = useState<POLine[]>([])
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const { data: poLines } = await supabase
      .from('purchase_orders')
      .select(`
        po_line_id,
        po_id,
        purchase_date,
        ordered_qty,
        expiry_date,
        boonz_product_id,
        boonz_products!inner(boonz_product_name),
        suppliers!inner(supplier_name)
      `)
      .eq('po_id', poId)
      .is('received_date', null)

    if (!poLines || poLines.length === 0) {
      setLines([])
      setLoading(false)
      return
    }

    const first = poLines[0]
    const s = first.suppliers as unknown as { supplier_name: string }
    setHeader({
      po_id: first.po_id,
      supplier_name: s.supplier_name,
      purchase_date: first.purchase_date,
    })

    const mapped: POLine[] = poLines.map((line) => {
      const p = line.boonz_products as unknown as { boonz_product_name: string }
      return {
        po_line_id: line.po_line_id,
        boonz_product_id: line.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        ordered_qty: line.ordered_qty ?? 0,
        received_qty: line.ordered_qty ?? 0,
        expiry_date: line.expiry_date ?? '',
        wh_location: '',
        overage: false,
      }
    })

    mapped.sort((a, b) => a.boonz_product_name.localeCompare(b.boonz_product_name))
    setLines(mapped)

    // Fetch last known locations for each product
    const productIds = mapped.map(l => l.boonz_product_id)
    if (productIds.length > 0) {
      const { data: locationData } = await supabase
        .from('warehouse_inventory')
        .select('boonz_product_id, wh_location')
        .in('boonz_product_id', productIds)
        .not('wh_location', 'is', null)
        .eq('status', 'Active')
        .order('created_at', { ascending: false })

      if (locationData) {
        // Build map of product_id -> most recent location
        const locationMap = new Map<string, string>()
        for (const row of locationData) {
          if (!locationMap.has(row.boonz_product_id) && row.wh_location) {
            locationMap.set(row.boonz_product_id, row.wh_location)
          }
        }

        // Pre-fill locations
        setLines(prev => prev.map(l => ({
          ...l,
          wh_location: locationMap.get(l.boonz_product_id) ?? l.wh_location
        })))
      }
    }

    setLoading(false)
  }, [poId])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  function updateLine(poLineId: string, field: 'received_qty' | 'expiry_date' | 'wh_location', value: string | number) {
    setLines((prev) =>
      prev.map((l) => {
        if (l.po_line_id !== poLineId) return l
        const updated = { ...l, [field]: value }
        if (field === 'received_qty') {
          updated.overage = (value as number) > l.ordered_qty
        }
        return updated
      })
    )
  }

  async function handleConfirm() {
    setSubmitting(true)
    setError(null)

    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]
    const batchTimestamp = Date.now()

    // 1. Mark PO lines as received
    const updatePromises = lines.map((line) =>
      supabase
        .from('purchase_orders')
        .update({ received_date: today })
        .eq('po_line_id', line.po_line_id)
    )

    const updateResults = await Promise.all(updatePromises)
    const updateError = updateResults.find((r) => r.error)
    if (updateError?.error) {
      setError(`Failed to update PO: ${updateError.error.message}`)
      setSubmitting(false)
      return
    }

    // 2. Insert warehouse inventory
    const inventoryInserts = lines.map((line) => ({
      boonz_product_id: line.boonz_product_id,
      snapshot_date: today,
      warehouse_stock: line.received_qty,
      expiration_date: line.expiry_date || null,
      batch_id: `${poId}-${batchTimestamp}`,
      wh_location: line.wh_location || null,
      status: 'Active',
    }))

    const { error: insertError } = await supabase
      .from('warehouse_inventory')
      .insert(inventoryInserts)

    if (insertError) {
      setError(`Failed to create inventory: ${insertError.message}`)
      setSubmitting(false)
      return
    }

    setSubmitted(true)
    setSubmitting(false)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading PO details…</p>
      </div>
    )
  }

  if (submitted) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <div className="mb-4 rounded-full bg-green-100 p-4 dark:bg-green-900">
          <span className="text-2xl">✓</span>
        </div>
        <h2 className="mb-2 text-lg font-semibold">Received ✓</h2>
        <p className="mb-4 text-sm text-neutral-500">
          {header?.po_id} has been received into inventory
        </p>
        <button
          onClick={() => router.push('/field/receiving')}
          className="rounded-lg bg-neutral-900 px-6 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          Back to receiving
        </button>
      </div>
    )
  }

  if (lines.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
          No pending lines for this PO
        </p>
        <button
          onClick={() => router.back()}
          className="mt-4 text-sm text-neutral-500 hover:text-neutral-700"
        >
          ← Back
        </button>
      </div>
    )
  }

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Receive Delivery" />

      {header && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{header.po_id}</h1>
          <p className="text-sm text-neutral-500">{header.supplier_name}</p>
          <p className="text-xs text-neutral-400">{formatDate(header.purchase_date)}</p>
        </div>
      )}

      <ul className="space-y-3">
        {lines.map((line) => (
          <li
            key={line.po_line_id}
            className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
          >
            <p className="text-sm font-semibold mb-2 truncate">
              {line.boonz_product_name}
            </p>
            <p className="text-xs text-neutral-500 mb-3">
              Ordered: {line.ordered_qty}
            </p>

            <div className="space-y-2">
              <div>
                <label className="block text-xs text-neutral-500 mb-0.5">
                  Received qty
                </label>
                <input
                  type="number"
                  min={0}
                  value={line.received_qty}
                  onChange={(e) =>
                    updateLine(line.po_line_id, 'received_qty', parseFloat(e.target.value) || 0)
                  }
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                />
                {line.overage && (
                  <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                    Quantity exceeds PO — are you sure?
                  </p>
                )}
              </div>

              <div>
                <label className="block text-xs text-neutral-500 mb-0.5">
                  Expiry date
                </label>
                <input
                  type="date"
                  value={line.expiry_date}
                  onChange={(e) =>
                    updateLine(line.po_line_id, 'expiry_date', e.target.value)
                  }
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>

              <div>
                <label className="block text-xs text-neutral-500 mb-0.5">
                  Warehouse location
                </label>
                <input
                  type="text"
                  value={line.wh_location}
                  onChange={(e) =>
                    updateLine(line.po_line_id, 'wh_location', e.target.value)
                  }
                  placeholder="e.g. A-01"
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>
            </div>
          </li>
        ))}
      </ul>

      {error && (
        <p className="mt-4 text-sm text-red-600 dark:text-red-400">{error}</p>
      )}

      <div className="fixed bottom-14 left-0 right-0 border-t border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <button
          onClick={handleConfirm}
          disabled={submitting}
          className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {submitting ? 'Confirming…' : 'Confirm receiving'}
        </button>
      </div>
    </div>
  )
}
