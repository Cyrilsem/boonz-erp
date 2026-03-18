'use client'

import { useEffect, useState, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface PickupLine {
  dispatch_id: string
  shelf_code: string
  pod_product_name: string
  quantity: number
}

interface PickupMachine {
  machine_id: string
  official_name: string
  line_count: number
  all_picked_up: boolean
  lines: PickupLine[]
}

export default function PickupPage() {
  const [machines, setMachines] = useState<PickupMachine[]>([])
  const [loading, setLoading] = useState(true)
  const [confirming, setConfirming] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)

  const fetchMachines = useCallback(async () => {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    // Only show machines where ALL lines are packed
    const { data: lines } = await supabase
      .from('refill_dispatching')
      .select(`
        dispatch_id, machine_id, packed, picked_up, quantity,
        machines!inner(official_name),
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `)
      .eq('dispatch_date', today)
      .eq('include', true)

    if (!lines || lines.length === 0) {
      setMachines([])
      setLoading(false)
      return
    }

    const grouped = new Map<string, {
      machine_id: string
      official_name: string
      total: number
      packed_count: number
      picked_up_count: number
      lines: PickupLine[]
    }>()

    for (const line of lines) {
      const m = line.machines as unknown as { official_name: string }
      const shelf = line.shelf_configurations as unknown as { shelf_code: string }
      const product = line.pod_products as unknown as { pod_product_name: string }

      const existing = grouped.get(line.machine_id)
      const pickupLine: PickupLine = {
        dispatch_id: line.dispatch_id,
        shelf_code: shelf.shelf_code,
        pod_product_name: product.pod_product_name,
        quantity: line.quantity ?? 0,
      }

      if (existing) {
        existing.total += 1
        if (line.packed) existing.packed_count += 1
        if (line.picked_up) existing.picked_up_count += 1
        existing.lines.push(pickupLine)
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          total: 1,
          packed_count: line.packed ? 1 : 0,
          picked_up_count: line.picked_up ? 1 : 0,
          lines: [pickupLine],
        })
      }
    }

    // Only include machines where ALL lines are packed
    const result: PickupMachine[] = Array.from(grouped.values())
      .filter((m) => m.packed_count === m.total)
      .map((m) => ({
        machine_id: m.machine_id,
        official_name: m.official_name,
        line_count: m.total,
        all_picked_up: m.picked_up_count === m.total,
        lines: m.lines.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code)),
      }))
      .sort((a, b) => a.official_name.localeCompare(b.official_name))

    setMachines(result)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchMachines()
  }, [fetchMachines])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchMachines()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchMachines)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchMachines)
    }
  }, [fetchMachines])

  async function handleConfirmPickup(machineId: string) {
    setConfirming(machineId)
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    await supabase
      .from('refill_dispatching')
      .update({ picked_up: true })
      .eq('machine_id', machineId)
      .eq('dispatch_date', today)

    setMachines((prev) =>
      prev.map((m) =>
        m.machine_id === machineId ? { ...m, all_picked_up: true } : m
      )
    )
    setExpanded(null)
    setConfirming(null)
  }

  function toggleExpanded(machineId: string) {
    setExpanded((prev) => (prev === machineId ? null : machineId))
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading pickup list…</p>
      </div>
    )
  }

  const readyMachines = machines.filter((m) => !m.all_picked_up)
  const collectedMachines = machines.filter((m) => m.all_picked_up)

  if (machines.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
          No machines ready for pickup
        </p>
        <p className="mt-1 text-sm text-neutral-500">
          Warehouse is still packing
        </p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Pickup" />

      {readyMachines.length > 0 && (
        <div className="mb-6">
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Ready for pickup
          </h2>
          <ul className="space-y-2">
            {readyMachines.map((machine) => {
              const isExpanded = expanded === machine.machine_id
              return (
                <li
                  key={machine.machine_id}
                  className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <button
                    onClick={() => toggleExpanded(machine.machine_id)}
                    className="flex w-full items-center gap-3 p-4 text-left"
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-base font-semibold truncate">
                        {machine.official_name}
                      </p>
                      <p className="text-sm text-neutral-500">
                        {machine.line_count} items
                      </p>
                    </div>
                    <span className="shrink-0 text-neutral-400">
                      {isExpanded ? '▲' : '▼'}
                    </span>
                  </button>

                  {isExpanded && (
                    <div className="border-t border-neutral-200 px-4 pb-4 dark:border-neutral-800">
                      <ul className="mt-3 space-y-1">
                        {machine.lines.map((line) => (
                          <li
                            key={line.dispatch_id}
                            className="flex items-center justify-between rounded bg-neutral-50 px-3 py-2 text-sm dark:bg-neutral-900"
                          >
                            <span className="font-mono text-xs text-neutral-400 mr-2">
                              {line.shelf_code}
                            </span>
                            <span className="flex-1 truncate">
                              {line.pod_product_name}
                            </span>
                            <span className="shrink-0 ml-2 text-neutral-500">
                              ×{line.quantity}
                            </span>
                          </li>
                        ))}
                      </ul>
                      <button
                        onClick={() => handleConfirmPickup(machine.machine_id)}
                        disabled={confirming === machine.machine_id}
                        className="mt-3 w-full rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                      >
                        {confirming === machine.machine_id ? 'Confirming…' : 'Confirm pickup'}
                      </button>
                    </div>
                  )}
                </li>
              )
            })}
          </ul>
        </div>
      )}

      {collectedMachines.length > 0 && (
        <div>
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Collected
          </h2>
          <ul className="space-y-2">
            {collectedMachines.map((machine) => (
              <li
                key={machine.machine_id}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 opacity-60 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex-1 min-w-0">
                  <p className="text-base font-semibold truncate">
                    {machine.official_name}
                  </p>
                  <p className="text-sm text-neutral-500">
                    {machine.line_count} items
                  </p>
                </div>
                <span className="shrink-0 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                  Collected ✓
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
