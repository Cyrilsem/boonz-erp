'use client'

import { useEffect, useState, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface PackingMachine {
  machine_id: string
  official_name: string
  sku_count: number
  packed_count: number
}

export default function PackingPage() {
  const [machines, setMachines] = useState<PackingMachine[]>([])
  const [loading, setLoading] = useState(true)

  const fetchMachines = useCallback(async () => {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    const { data: lines } = await supabase
      .from('refill_dispatching')
      .select('dispatch_id, machine_id, packed, machines!inner(official_name)')
      .eq('dispatch_date', today)
      .eq('include', true)

    if (!lines || lines.length === 0) {
      setMachines([])
      setLoading(false)
      return
    }

    const grouped = new Map<string, PackingMachine>()

    for (const line of lines) {
      const m = line.machines as unknown as { official_name: string }
      const existing = grouped.get(line.machine_id)
      if (existing) {
        existing.sku_count += 1
        if (line.packed) existing.packed_count += 1
      } else {
        grouped.set(line.machine_id, {
          machine_id: line.machine_id,
          official_name: m.official_name,
          sku_count: 1,
          packed_count: line.packed ? 1 : 0,
        })
      }
    }

    const sorted = Array.from(grouped.values()).sort((a, b) =>
      a.official_name.localeCompare(b.official_name)
    )
    setMachines(sorted)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchMachines()
  }, [fetchMachines])

  // Re-fetch when returning from detail page (visibility change)
  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') {
        fetchMachines()
      }
    }
    document.addEventListener('visibilitychange', handleVisibility)
    // Also re-fetch on window focus (covers back navigation)
    window.addEventListener('focus', fetchMachines)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchMachines)
    }
  }, [fetchMachines])

  if (loading) {
    return (
      <>
        <FieldHeader title="Packing" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading packing list…</p>
        </div>
      </>
    )
  }

  if (machines.length === 0) {
    return (
      <>
        <FieldHeader title="Packing" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No machines to pack today
          </p>
        </div>
      </>
    )
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Packing" />
      <ul className="space-y-2">
        {machines.map((machine) => {
          const ready = machine.packed_count === machine.sku_count
          return (
            <li key={machine.machine_id}>
              <Link
                href={`/field/packing/${machine.machine_id}`}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
              >
                <div className="flex-1 min-w-0">
                  <p className="text-base font-semibold truncate">
                    {machine.official_name}
                  </p>
                  <p className="text-sm text-neutral-500">
                    {machine.packed_count}/{machine.sku_count} packed
                  </p>
                </div>
                <span
                  className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium ${
                    ready
                      ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200'
                      : 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400'
                  }`}
                >
                  {ready ? 'Ready' : 'Packing'}
                </span>
              </Link>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
