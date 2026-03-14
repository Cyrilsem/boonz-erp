'use client'

import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'

interface PickupMachine {
  machine_id: string
  official_name: string
  sku_count: number
  all_packed: boolean
  all_picked_up: boolean
}

export default function PickupPage() {
  const [machines, setMachines] = useState<PickupMachine[]>([])
  const [loading, setLoading] = useState(true)
  const [confirming, setConfirming] = useState<string | null>(null)

  useEffect(() => {
    fetchMachines()
  }, [])

  async function fetchMachines() {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    const { data: lines } = await supabase
      .from('refill_dispatching')
      .select('dispatch_id, machine_id, packed, picked_up, machines!inner(official_name)')
      .eq('dispatch_date', today)
      .eq('include', true)

    if (!lines || lines.length === 0) {
      setMachines([])
      setLoading(false)
      return
    }

    const grouped = new Map<string, PickupMachine>()

    for (const line of lines) {
      const m = line.machines as unknown as { official_name: string }
      const existing = grouped.get(line.machine_id)
      if (existing) {
        existing.sku_count += 1
        if (!line.packed) existing.all_packed = false
        if (!line.picked_up) existing.all_picked_up = false
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          sku_count: 1,
          all_packed: !!line.packed,
          all_picked_up: !!line.picked_up,
        })
      }
    }

    const sorted = Array.from(grouped.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name)
    )
    setMachines(sorted)
    setLoading(false)
  }

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
    setConfirming(null)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading pickup list…</p>
      </div>
    )
  }

  if (machines.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
          No machines for pickup today
        </p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4">
      <h1 className="mb-4 text-xl font-semibold">Pickup</h1>
      <ul className="space-y-2">
        {machines.map((machine) => (
          <li
            key={machine.machine_id}
            className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
          >
            <div className="flex-1 min-w-0">
              <p className="text-base font-semibold truncate">
                {machine.official_name}
              </p>
              <p className="text-sm text-neutral-500">
                {machine.sku_count} lines
              </p>
            </div>
            <span
              className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium ${
                machine.all_packed
                  ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200'
                  : 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200'
              }`}
            >
              {machine.all_packed ? 'Packed ✓' : 'Packing…'}
            </span>
            {machine.all_picked_up ? (
              <span className="shrink-0 rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                Picked up ✓
              </span>
            ) : (
              <button
                onClick={() => handleConfirmPickup(machine.machine_id)}
                disabled={!machine.all_packed || confirming === machine.machine_id}
                className="shrink-0 rounded-full bg-neutral-900 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-40 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              >
                {confirming === machine.machine_id ? 'Confirming…' : 'Confirm pickup'}
              </button>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
