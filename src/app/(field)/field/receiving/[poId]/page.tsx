'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

interface ReceiveBatch {
  batch_key: string
  received_qty: number
  expiry_date: string
}

interface ReceiveLine {
  po_line_id: string
  po_id: string
  boonz_product_id: string
  boonz_product_name: string
  ordered_qty: number
  supplier_id: string
  price_per_unit_aed: number | null
  purchase_date: string
  wh_location: string
  batches: ReceiveBatch[]
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

function generateKey(): string {
  return Math.random().toString(36).slice(2)
}

export default function ReceivingDetailPage() {
  const params = useParams<{ poId: string }>()
  const router = useRouter()
  const poId = decodeURIComponent(params.poId)

  const [header, setHeader] = useState<POHeader | null>(null)
  const [lines, setLines] = useState<ReceiveLine[]>([])
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
        supplier_id,
        price_per_unit_aed,
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

    const mapped: ReceiveLine[] = poLines.map((line) => {
      const p = line.boonz_products as unknown as { boonz_product_name: string }
      return {
        po_line_id: line.po_line_id,
        po_id: line.po_id,
        boonz_product_id: line.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        ordered_qty: line.ordered_qty ?? 0,
        supplier_id: (line.supplier_id as string) ?? '',
        price_per_unit_aed: (line.price_per_unit_aed as number | null) ?? null,
        purchase_date: line.purchase_date,
        wh_location: '',
        batches: [
          {
            batch_key: generateKey(),
            received_qty: line.ordered_qty ?? 0,
            expiry_date: (line.expiry_date as string | null) ?? '',
          },
        ],
      }
    })

    mapped.sort((a, b) => a.boonz_product_name.localeCompare(b.boonz_product_name))
    setLines(mapped)

    // Pre-fill warehouse locations from most recent active batch per product
    const productIds = mapped.map((l) => l.boonz_product_id)
    if (productIds.length > 0) {
      const { data: locationData } = await supabase
        .from('warehouse_inventory')
        .select('boonz_product_id, wh_location')
        .in('boonz_product_id', productIds)
        .not('wh_location', 'is', null)
        .eq('status', 'Active')
        .order('created_at', { ascending: false })

      if (locationData) {
        const locationMap = new Map<string, string>()
        for (const row of locationData) {
          if (!locationMap.has(row.boonz_product_id) && row.wh_location) {
            locationMap.set(row.boonz_product_id, row.wh_location)
          }
        }
        setLines((prev) =>
          prev.map((l) => ({
            ...l,
            wh_location: locationMap.get(l.boonz_product_id) ?? l.wh_location,
          }))
        )
      }
    }

    setLoading(false)
  }, [poId])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  function addBatch(poLineId: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: [
                ...l.batches,
                { batch_key: generateKey(), received_qty: 0, expiry_date: '' },
              ],
            }
      )
    )
  }

  function removeBatch(poLineId: string, batchKey: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : { ...l, batches: l.batches.filter((b) => b.batch_key !== batchKey) }
      )
    )
  }

  function updateBatch(
    poLineId: string,
    batchKey: string,
    field: 'received_qty' | 'expiry_date',
    value: string | number
  ) {
    setLines((prev) =>
      prev.map((l) =>
        l.po_line_id !== poLineId
          ? l
          : {
              ...l,
              batches: l.batches.map((b) =>
                b.batch_key !== batchKey ? b : { ...b, [field]: value }
              ),
            }
      )
    )
  }

  function updateWHLocation(poLineId: string, value: string) {
    setLines((prev) =>
      prev.map((l) => (l.po_line_id !== poLineId ? l : { ...l, wh_location: value }))
    )
  }

  async function handleConfirm() {
    setSubmitting(true)
    setError(null)

    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    for (const line of lines) {
      const activeBatches = line.batches.filter((b) => b.received_qty > 0)
      if (activeBatches.length === 0) continue

      for (let i = 0; i < activeBatches.length; i++) {
        const batch = activeBatches[i]

        if (i === 0) {
          // Update original PO line with received date, actual qty, and expiry
          const { error: updateErr } = await supabase
            .from('purchase_orders')
            .update({
              received_date: today,
              expiry_date: batch.expiry_date || null,
              ordered_qty: batch.received_qty,
            })
            .eq('po_line_id', line.po_line_id)

          if (updateErr) {
            setError(`Failed to update PO: ${updateErr.message}`)
            setSubmitting(false)
            return
          }
        } else {
          // Insert additional PO line for extra batches
          const { error: insertErr } = await supabase.from('purchase_orders').insert({
            po_id: line.po_id,
            supplier_id: line.supplier_id,
            boonz_product_id: line.boonz_product_id,
            ordered_qty: batch.received_qty,
            price_per_unit_aed: line.price_per_unit_aed,
            expiry_date: batch.expiry_date || null,
            purchase_date: line.purchase_date,
            received_date: today,
          })

          if (insertErr) {
            setError(`Failed to insert batch: ${insertErr.message}`)
            setSubmitting(false)
            return
          }
        }

        // Insert warehouse inventory row for each batch
        const { error: whErr } = await supabase.from('warehouse_inventory').insert({
          boonz_product_id: line.boonz_product_id,
          warehouse_stock: batch.received_qty,
          expiration_date: batch.expiry_date || null,
          batch_id: `${poId}-B${i + 1}`,
          wh_location: line.wh_location || null,
          status: 'Active',
          snapshot_date: today,
        })

        if (whErr) {
          setError(`Failed to create inventory: ${whErr.message}`)
          setSubmitting(false)
          return
        }
      }
    }

    setSubmitted(true)
    setSubmitting(false)
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading PO details…</p>
        </div>
      </>
    )
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
          <button
            onClick={() => router.push('/field/receiving')}
            className="rounded-lg bg-neutral-900 px-6 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            Back to receiving
          </button>
        </div>
      </>
    )
  }

  if (lines.length === 0) {
    return (
      <>
        <FieldHeader title="Receive Delivery" />
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
      </>
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

      <ul className="space-y-4">
        {lines.map((line) => {
          const batchTotal = line.batches.reduce((sum, b) => sum + b.received_qty, 0)
          const totalColor =
            batchTotal === line.ordered_qty
              ? 'text-green-600 dark:text-green-400'
              : batchTotal > line.ordered_qty
              ? 'text-red-600 dark:text-red-400'
              : 'text-amber-600 dark:text-amber-400'

          return (
            <li
              key={line.po_line_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
            >
              {/* Product header */}
              <p className="mb-1 text-sm font-bold">{line.boonz_product_name}</p>
              <p className="mb-3 text-xs text-neutral-500">Ordered: {line.ordered_qty} units</p>

              {/* Sub-batch rows */}
              <div className="space-y-3">
                {line.batches.map((batch, bIdx) => (
                  <div
                    key={batch.batch_key}
                    className="ml-2 rounded-lg border border-neutral-100 bg-neutral-50 p-3 dark:border-neutral-700 dark:bg-neutral-900"
                  >
                    <div className="mb-2 flex items-center justify-between">
                      <span className="text-xs font-semibold text-neutral-500">
                        Batch {bIdx + 1}
                      </span>
                      {line.batches.length > 1 && (
                        <button
                          onClick={() => removeBatch(line.po_line_id, batch.batch_key)}
                          className="text-xs text-red-500 hover:text-red-700 dark:text-red-400"
                        >
                          × remove
                        </button>
                      )}
                    </div>

                    <div className="grid grid-cols-2 gap-2">
                      <div>
                        <label className="mb-0.5 block text-xs text-neutral-500">Qty</label>
                        <input
                          type="number"
                          min={0}
                          value={batch.received_qty}
                          onChange={(e) =>
                            updateBatch(
                              line.po_line_id,
                              batch.batch_key,
                              'received_qty',
                              parseFloat(e.target.value) || 0
                            )
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                        />
                      </div>
                      <div>
                        <label className="mb-0.5 block text-xs text-neutral-500">Expiry date</label>
                        <input
                          type="date"
                          value={batch.expiry_date}
                          onChange={(e) =>
                            updateBatch(
                              line.po_line_id,
                              batch.batch_key,
                              'expiry_date',
                              e.target.value
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
                {batchTotal} of {line.ordered_qty} received
              </p>

              {/* Warehouse location */}
              <div className="mt-3">
                <label className="mb-0.5 block text-xs text-neutral-500">
                  Warehouse location
                </label>
                <input
                  type="text"
                  value={line.wh_location}
                  onChange={(e) => updateWHLocation(line.po_line_id, e.target.value)}
                  placeholder="e.g. A-01"
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
                />
              </div>
            </li>
          )
        })}
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
