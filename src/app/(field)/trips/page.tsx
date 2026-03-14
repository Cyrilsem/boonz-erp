'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'

interface TripStop {
  machine_id: string
  official_name: string
  pod_location: string | null
  pod_address: string | null
  sku_count: number
  done: boolean
}

export default function TripsPage() {
  const [stops, setStops] = useState<TripStop[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    async function fetchStops() {
      const supabase = createClient()
      const today = new Date().toISOString().split('T')[0]

      const { data: lines } = await supabase
        .from('refill_dispatching')
        .select('dispatch_id, machine_id, dispatched, machines!inner(official_name, pod_location, pod_address)')
        .eq('dispatch_date', today)
        .eq('include', true)
        .eq('picked_up', true)

      if (!lines || lines.length === 0) {
        setStops([])
        setLoading(false)
        return
      }

      const grouped = new Map<string, TripStop>()

      for (const line of lines) {
        const m = line.machines as unknown as {
          official_name: string
          pod_location: string | null
          pod_address: string | null
        }
        const existing = grouped.get(line.machine_id)
        if (existing) {
          existing.sku_count += 1
          if (!line.dispatched) existing.done = false
        } else {
          grouped.set(line.machine_id, {
            machine_id: line.machine_id,
            official_name: m.official_name,
            pod_location: m.pod_location,
            pod_address: m.pod_address,
            sku_count: 1,
            done: !!line.dispatched,
          })
        }
      }

      const sorted = Array.from(grouped.values()).sort((a, b) =>
        a.official_name.localeCompare(b.official_name)
      )
      setStops(sorted)
      setLoading(false)
    }

    fetchStops()
  }, [])

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading trips…</p>
      </div>
    )
  }

  if (stops.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
          No stops for today
        </p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4">
      <h1 className="mb-4 text-xl font-semibold">Today&apos;s Trips</h1>
      <ul className="space-y-2">
        {stops.map((stop, idx) => (
          <li key={stop.machine_id}>
            <Link
              href={`/field/trips/${stop.machine_id}`}
              className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
            >
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-neutral-100 text-sm font-semibold dark:bg-neutral-800">
                {idx + 1}
              </span>
              <div className="flex-1 min-w-0">
                <p className="text-base font-semibold truncate">
                  {stop.official_name}
                </p>
                {stop.pod_location && (
                  <p className="text-sm text-neutral-500 truncate">
                    {stop.pod_location}
                  </p>
                )}
              </div>
              <span className="shrink-0 rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-medium dark:bg-neutral-800">
                {stop.sku_count} lines
              </span>
              <span
                className={`shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium ${
                  stop.done
                    ? 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200'
                    : 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400'
                }`}
              >
                {stop.done ? 'Done' : 'Pending'}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
