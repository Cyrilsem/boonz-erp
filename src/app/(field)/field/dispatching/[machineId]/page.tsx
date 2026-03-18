'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

interface MachineInfo {
  official_name: string
  pod_location: string | null
}

interface DispatchLine {
  dispatch_id: string
  shelf_code: string
  pod_product_name: string
  quantity: number
  filled_quantity: number
  dispatched: boolean
  comment: string
}

export default function DispatchingDetailPage() {
  const params = useParams<{ machineId: string }>()
  const router = useRouter()
  const machineId = params.machineId

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<DispatchLine[]>([])
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
        quantity,
        filled_quantity,
        dispatched,
        comment,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `)
      .eq('dispatch_date', today)
      .eq('include', true)
      .eq('machine_id', machineId)
      .eq('picked_up', true)

    if (dispatchLines) {
      const mapped: DispatchLine[] = dispatchLines.map((line) => {
        const shelf = line.shelf_configurations as unknown as { shelf_code: string }
        const product = line.pod_products as unknown as { pod_product_name: string }
        return {
          dispatch_id: line.dispatch_id,
          shelf_code: shelf.shelf_code,
          pod_product_name: product.pod_product_name,
          quantity: line.quantity ?? 0,
          filled_quantity: line.filled_quantity ?? line.quantity ?? 0,
          dispatched: !!line.dispatched,
          comment: (line.comment as string) ?? '',
        }
      })
      mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code))
      setLines(mapped)
    }

    setLoading(false)
  }, [machineId])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  function updateQuantity(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, filled_quantity: value } : l
      )
    )
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

  async function handleDispatchLine(dispatchId: string) {
    const line = lines.find((l) => l.dispatch_id === dispatchId)
    if (!line || line.dispatched) return

    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({
        dispatched: true,
        filled_quantity: line.filled_quantity,
        item_added: true,
        comment: line.comment.trim() || null,
      })
      .eq('dispatch_id', dispatchId)

    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, dispatched: true } : l
      )
    )
  }

  async function handleMarkAllDispatched() {
    setMarkingAll(true)
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    // For unedited lines, use planned quantity
    const updates = lines
      .filter((l) => !l.dispatched)
      .map((l) =>
        supabase
          .from('refill_dispatching')
          .update({
            dispatched: true,
            filled_quantity: l.filled_quantity,
            item_added: true,
            comment: l.comment.trim() || null,
          })
          .eq('dispatch_id', l.dispatch_id)
          .eq('dispatch_date', today)
      )

    await Promise.all(updates)
    setLines((prev) => prev.map((l) => ({ ...l, dispatched: true })))
    setMarkingAll(false)
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Dispatch Detail" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading dispatch details…</p>
        </div>
      </>
    )
  }

  const doneCount = lines.filter((l) => l.dispatched).length
  const allDone = lines.length > 0 && doneCount === lines.length

  // Group by shelf_code
  const grouped = new Map<string, DispatchLine[]>()
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
      <FieldHeader title="Dispatch Detail" />

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          <div className="flex items-center gap-2">
            {machine.pod_location && (
              <p className="text-sm text-neutral-500">{machine.pod_location}</p>
            )}
            <span className="text-sm text-neutral-400">
              · {doneCount}/{lines.length} dispatched
            </span>
          </div>
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
                className="rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex items-center gap-3">
                  <button
                    onClick={() => handleDispatchLine(line.dispatch_id)}
                    disabled={line.dispatched}
                    className={`flex h-6 w-6 shrink-0 items-center justify-center rounded border text-sm ${
                      line.dispatched
                        ? 'border-green-500 bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                        : 'border-neutral-300 bg-white hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-900'
                    }`}
                  >
                    {line.dispatched ? '✓' : ''}
                  </button>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium truncate">
                      {line.pod_product_name}
                    </p>
                    <p className="text-xs text-neutral-500">
                      Planned: {line.quantity}
                    </p>
                  </div>
                  <input
                    type="number"
                    min={0}
                    value={line.filled_quantity}
                    onChange={(e) =>
                      updateQuantity(line.dispatch_id, parseFloat(e.target.value) || 0)
                    }
                    disabled={line.dispatched}
                    className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm disabled:opacity-50 dark:border-neutral-600 dark:bg-neutral-900"
                  />
                </div>
                <input
                  type="text"
                  value={line.comment}
                  onChange={(e) => updateComment(line.dispatch_id, e.target.value)}
                  onBlur={(e) => saveComment(line.dispatch_id, e.target.value)}
                  disabled={line.dispatched}
                  placeholder="Add note…"
                  className="mt-2 w-full rounded border border-neutral-200 px-2 py-1 text-xs text-neutral-600 placeholder:text-neutral-400 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400"
                />
              </li>
            ))}
          </ul>
        </div>
      ))}

      {!allDone && (
        <button
          onClick={handleMarkAllDispatched}
          disabled={markingAll}
          className="mt-4 w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {markingAll ? 'Marking…' : 'Mark all dispatched'}
        </button>
      )}

      {allDone && (
        <p className="mt-4 text-center text-sm font-medium text-green-600 dark:text-green-400">
          All items dispatched ✓
        </p>
      )}
    </div>
  )
}
