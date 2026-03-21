'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'
import { getExpiryStyle } from '@/app/(field)/utils/expiry'

// ─── Types ────────────────────────────────────────────────────────────────────

interface PackingLine {
  dispatch_id: string
  boonz_product_id: string
  shelf_code: string
  pod_product_name: string
  quantity: number
  packed: boolean
  warehouse_stock: number
  comment: string
}

interface MachineInfo {
  official_name: string
  pod_location: string | null
}

interface BatchAllocation {
  wh_inventory_id: string
  expiry_date: string | null
  qty: number
}

interface FifoResult {
  allocations: BatchAllocation[]
  primary_expiry: string | null
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDMY(date: string | null): string {
  if (!date) return '—'
  return new Date(date + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: '2-digit',
  })
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PackingDetailPage() {
  const params = useParams<{ machineId: string }>()
  const machineId = params.machineId

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<PackingLine[]>([])
  const [fifoMap, setFifoMap] = useState<Record<string, FifoResult>>({})
  const [loading, setLoading] = useState(true)
  const [markingAll, setMarkingAll] = useState(false)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    const { data: machineData } = await supabase
      .from('machines')
      .select('official_name, pod_location')
      .eq('machine_id', machineId)
      .single()

    if (machineData) setMachine(machineData)

    const { data: dispatchLines } = await supabase
      .from('refill_dispatching')
      .select(`
        dispatch_id,
        boonz_product_id,
        quantity,
        packed,
        comment,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `)
      .eq('dispatch_date', today)
      .eq('include', true)
      .eq('machine_id', machineId)

    if (!dispatchLines) {
      setLines([])
      setLoading(false)
      return
    }

    // ── FIFO batch fetch ────────────────────────────────────────────────────
    const boonzProductIds = dispatchLines
      .map((l) => l.boonz_product_id)
      .filter((id): id is string => id !== null)

    interface WBatch {
      wh_inventory_id: string
      boonz_product_id: string
      warehouse_stock: number
      expiration_date: string | null
    }

    let rawBatches: WBatch[] = []

    if (boonzProductIds.length > 0) {
      const { data: batchData } = await supabase
        .from('warehouse_inventory')
        .select('wh_inventory_id, boonz_product_id, warehouse_stock, expiration_date')
        .in('boonz_product_id', boonzProductIds)
        .eq('status', 'Active')
        .gt('warehouse_stock', 0)
        .order('expiration_date', { ascending: true, nullsFirst: false })

      rawBatches = (batchData ?? []) as WBatch[]
    }

    // Build mutable batch pool per product (already ordered FIFO from DB)
    const batchPool = new Map<string, { wh_inventory_id: string; expiry_date: string | null; available: number }[]>()
    const stockMap = new Map<string, number>()

    for (const b of rawBatches) {
      if (!batchPool.has(b.boonz_product_id)) batchPool.set(b.boonz_product_id, [])
      batchPool.get(b.boonz_product_id)!.push({
        wh_inventory_id: b.wh_inventory_id,
        expiry_date: b.expiration_date,
        available: b.warehouse_stock ?? 0,
      })
      stockMap.set(b.boonz_product_id, (stockMap.get(b.boonz_product_id) ?? 0) + (b.warehouse_stock ?? 0))
    }

    // FIFO allocation — sort lines by dispatch_id for determinism
    const sortedForAlloc = [...dispatchLines].sort((a, b) => a.dispatch_id.localeCompare(b.dispatch_id))
    const fifo: Record<string, FifoResult> = {}

    for (const line of sortedForAlloc) {
      const productId = line.boonz_product_id ?? ''
      const batches = batchPool.get(productId) ?? []
      let remaining = line.quantity ?? 0
      const allocations: BatchAllocation[] = []

      for (const batch of batches) {
        if (remaining <= 0) break
        if (batch.available <= 0) continue
        const take = Math.min(batch.available, remaining)
        allocations.push({ wh_inventory_id: batch.wh_inventory_id, expiry_date: batch.expiry_date, qty: take })
        batch.available -= take
        remaining -= take
      }

      fifo[line.dispatch_id] = {
        allocations,
        primary_expiry: allocations[0]?.expiry_date ?? null,
      }
    }

    setFifoMap(fifo)

    // Map lines
    const mapped: PackingLine[] = dispatchLines.map((line) => {
      const shelf = line.shelf_configurations as unknown as { shelf_code: string }
      const product = line.pod_products as unknown as { pod_product_name: string }
      return {
        dispatch_id: line.dispatch_id,
        boonz_product_id: line.boonz_product_id ?? '',
        shelf_code: shelf.shelf_code,
        pod_product_name: product.pod_product_name,
        quantity: line.quantity ?? 0,
        packed: !!line.packed,
        warehouse_stock: stockMap.get(line.boonz_product_id ?? '') ?? 0,
        comment: (line.comment as string) ?? '',
      }
    })

    mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code))
    setLines(mapped)
    setLoading(false)
  }, [machineId])

  useEffect(() => { fetchData() }, [fetchData])

  async function handleTogglePacked(dispatchId: string) {
    const supabase = createClient()
    const fifo = fifoMap[dispatchId]
    const update: Record<string, unknown> = { packed: true }
    if (fifo?.primary_expiry) update.expiry_date = fifo.primary_expiry

    await supabase.from('refill_dispatching').update(update).eq('dispatch_id', dispatchId)
    setLines((prev) => prev.map((l) => l.dispatch_id === dispatchId ? { ...l, packed: true } : l))
  }

  async function handleMarkAllPacked() {
    setMarkingAll(true)
    const supabase = createClient()

    // Sequential — each line may have a different FIFO expiry
    for (const line of lines.filter((l) => !l.packed)) {
      const fifo = fifoMap[line.dispatch_id]
      const update: Record<string, unknown> = { packed: true }
      if (fifo?.primary_expiry) update.expiry_date = fifo.primary_expiry
      await supabase.from('refill_dispatching').update(update).eq('dispatch_id', line.dispatch_id)
    }

    setLines((prev) => prev.map((l) => ({ ...l, packed: true })))
    setMarkingAll(false)
  }

  function updateComment(dispatchId: string, value: string) {
    setLines((prev) => prev.map((l) => l.dispatch_id === dispatchId ? { ...l, comment: value } : l))
  }

  async function saveComment(dispatchId: string, value: string) {
    const supabase = createClient()
    await supabase.from('refill_dispatching').update({ comment: value.trim() || null }).eq('dispatch_id', dispatchId)
  }

  function stockColor(stock: number, planned: number): string {
    if (stock === 0) return 'text-red-600 dark:text-red-400'
    if (stock < planned) return 'text-amber-600 dark:text-amber-400'
    return 'text-green-600 dark:text-green-400'
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Machine Detail" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading packing details…</p>
        </div>
      </>
    )
  }

  const allPacked = lines.length > 0 && lines.every((l) => l.packed)

  const grouped = new Map<string, PackingLine[]>()
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? []
    existing.push(line)
    grouped.set(line.shelf_code, existing)
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) => a[0].localeCompare(b[0]))

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Machine Detail" />

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          {machine.pod_location && (
            <p className="text-sm text-neutral-500">{machine.pod_location}</p>
          )}
        </div>
      )}

      {shelves.map(([shelfCode, shelfLines]) => (
        <div key={shelfCode} className="mb-4">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-1">
            {shelfLines.map((line) => {
              const fifo = fifoMap[line.dispatch_id]
              const allocations = fifo?.allocations ?? []
              const hasStock = allocations.length > 0
              const isMultiBatch = allocations.length > 1

              return (
                <li
                  key={line.dispatch_id}
                  className="flex items-start gap-3 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <button
                    onClick={() => handleTogglePacked(line.dispatch_id)}
                    disabled={line.packed}
                    className={`mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded border text-sm ${
                      line.packed
                        ? 'border-green-500 bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                        : 'border-neutral-300 bg-white hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-900'
                    }`}
                  >
                    {line.packed ? '✓' : ''}
                  </button>

                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm font-medium">{line.pod_product_name}</p>

                    {/* FIFO expiry block */}
                    {!hasStock ? (
                      <p className="mt-0.5 inline-flex items-center gap-1 rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                        ⚠ No stock found in warehouse
                      </p>
                    ) : isMultiBatch ? (
                      <div className="mt-1 space-y-0.5 rounded bg-amber-50 px-2 py-1 dark:bg-amber-900/20">
                        {allocations.map((a, i) => {
                          const style = getExpiryStyle(a.expiry_date)
                          return (
                            <p key={i} className="text-xs">
                              <span className="font-bold">Qty: {a.qty}</span>
                              {'  '}
                              <span className="font-bold">Expiry:</span>{' '}
                              <span className={style.qtyColor}>{formatDMY(a.expiry_date)}</span>
                            </p>
                          )
                        })}
                      </div>
                    ) : (
                      <p className="mt-0.5 text-xs">
                        <span className="font-bold">Qty: {allocations[0].qty}</span>
                        {'  '}
                        <span className="font-bold">Expiry:</span>{' '}
                        <span className={getExpiryStyle(allocations[0].expiry_date).qtyColor}>
                          {formatDMY(allocations[0].expiry_date)}
                        </span>
                      </p>
                    )}

                    <p className="mt-0.5 text-xs">
                      <span className={stockColor(line.warehouse_stock, line.quantity)}>
                        {line.warehouse_stock} in stock
                      </span>
                    </p>

                    <input
                      type="text"
                      value={line.comment}
                      onChange={(e) => updateComment(line.dispatch_id, e.target.value)}
                      onBlur={(e) => saveComment(line.dispatch_id, e.target.value)}
                      placeholder="Add note…"
                      className="mt-1 w-full rounded border border-neutral-200 px-2 py-1 text-xs text-neutral-600 placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400"
                    />
                  </div>
                </li>
              )
            })}
          </ul>
        </div>
      ))}

      {!allPacked && (
        <button
          onClick={handleMarkAllPacked}
          disabled={markingAll}
          className="mt-4 w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {markingAll ? 'Marking…' : 'Mark all packed'}
        </button>
      )}

      {allPacked && (
        <p className="mt-4 text-center text-sm font-medium text-green-600 dark:text-green-400">
          All items packed ✓
        </p>
      )}
    </div>
  )
}
