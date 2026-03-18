'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

interface PackingLine {
  dispatch_id: string
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

export default function PackingDetailPage() {
  const params = useParams<{ machineId: string }>()
  const router = useRouter()
  const machineId = params.machineId

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<PackingLine[]>([])
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

    if (machineData) {
      setMachine(machineData)
    }

    const { data: dispatchLines } = await supabase
      .from('refill_dispatching')
      .select(`
        dispatch_id,
        machine_id,
        quantity,
        packed,
        comment,
        boonz_product_id,
        shelf_id,
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

    const boonzProductIds = dispatchLines
      .map((l) => l.boonz_product_id)
      .filter((id): id is string => id !== null)

    let stockMap = new Map<string, number>()
    if (boonzProductIds.length > 0) {
      const { data: stockData } = await supabase
        .from('warehouse_inventory')
        .select('boonz_product_id, warehouse_stock')
        .in('boonz_product_id', boonzProductIds)
        .eq('status', 'Active')

      if (stockData) {
        for (const row of stockData) {
          const current = stockMap.get(row.boonz_product_id) ?? 0
          stockMap.set(row.boonz_product_id, current + (row.warehouse_stock ?? 0))
        }
      }
    }

    const mapped: PackingLine[] = dispatchLines.map((line) => {
      const shelf = line.shelf_configurations as unknown as { shelf_code: string }
      const product = line.pod_products as unknown as { pod_product_name: string }
      return {
        dispatch_id: line.dispatch_id,
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

  useEffect(() => {
    fetchData()
  }, [fetchData])

  async function handleTogglePacked(dispatchId: string) {
    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({ packed: true })
      .eq('dispatch_id', dispatchId)

    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, packed: true } : l
      )
    )
  }

  async function handleMarkAllPacked() {
    setMarkingAll(true)
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    await supabase
      .from('refill_dispatching')
      .update({ packed: true })
      .eq('machine_id', machineId)
      .eq('dispatch_date', today)

    setLines((prev) => prev.map((l) => ({ ...l, packed: true })))
    setMarkingAll(false)
  }

  function updateComment(dispatchId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, comment: value } : l
      )
    )
  }

  async function saveComment(dispatchId: string, value: string) {
    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({ comment: value.trim() || null })
      .eq('dispatch_id', dispatchId)
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

  // Group by shelf_code
  const grouped = new Map<string, PackingLine[]>()
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? []
    existing.push(line)
    grouped.set(line.shelf_code, existing)
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) =>
    a[0].localeCompare(b[0])
  )

  return (
    <div className="px-4 py-4">
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
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-1">
            {shelfLines.map((line) => (
              <li
                key={line.dispatch_id}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <button
                  onClick={() => handleTogglePacked(line.dispatch_id)}
                  disabled={line.packed}
                  className={`flex h-6 w-6 shrink-0 items-center justify-center rounded border text-sm ${
                    line.packed
                      ? 'border-green-500 bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                      : 'border-neutral-300 bg-white hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-900'
                  }`}
                >
                  {line.packed ? '✓' : ''}
                </button>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium truncate">
                    {line.pod_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    Qty: {line.quantity} ·{' '}
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
            ))}
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
