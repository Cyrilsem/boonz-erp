'use client'

import { useEffect, useState, useMemo } from 'react'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface PodRow {
  pod_inventory_id: string
  boonz_product_name: string
  machine_name: string
  current_stock: number
  expiration_date: string | null
}

type PodFilter = 'expired' | '3days' | '7days' | '30days' | 'all'

const FILTER_OPTIONS: { label: string; value: PodFilter }[] = [
  { label: 'Expired', value: 'expired' },
  { label: '< 3 days', value: '3days' },
  { label: '< 7 days', value: '7days' },
  { label: '< 30 days', value: '30days' },
  { label: 'All active', value: 'all' },
]

function todayISO(): string {
  return new Date().toISOString().split('T')[0]
}

function daysUntilExpiry(date: string | null): number | null {
  if (!date) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(date + 'T00:00:00')
  return Math.ceil((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24))
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

function PodExpiryBadge({ days }: { days: number | null }) {
  if (days === null) return null
  if (days <= 0) {
    return (
      <span className="rounded-full bg-red-100 px-3 py-1 text-sm font-semibold text-red-700 dark:bg-red-900 dark:text-red-300">
        Expired
      </span>
    )
  }
  const label = days === 0 ? 'Today' : `${days}d left`
  if (days <= 3) {
    return (
      <span className="rounded-full bg-red-100 px-3 py-1 text-sm font-semibold text-red-700 dark:bg-red-900 dark:text-red-300">
        {label}
      </span>
    )
  }
  if (days <= 7) {
    return (
      <span className="rounded-full bg-amber-100 px-3 py-1 text-sm font-semibold text-amber-700 dark:bg-amber-900 dark:text-amber-300">
        {label}
      </span>
    )
  }
  return (
    <span className="rounded-full bg-orange-100 px-3 py-1 text-sm font-semibold text-orange-700 dark:bg-orange-900 dark:text-orange-300">
      {label}
    </span>
  )
}

export default function PodInventoryPage() {
  const [rows, setRows] = useState<PodRow[]>([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState<PodFilter>('7days')
  const [search, setSearch] = useState('')

  useEffect(() => {
    async function fetchData() {
      const supabase = createClient()

      const { data, error } = await supabase
        .from('pod_inventory')
        .select(`
          pod_inventory_id,
          current_stock,
          expiration_date,
          status,
          boonz_products ( boonz_product_name ),
          machines ( official_name )
        `)
        .eq('status', 'Active')
        .order('expiration_date', { ascending: true })

      console.log('[PodInventory] fetch:', data?.length, error)

      if (data) {
        const mapped: PodRow[] = data.map((row) => {
          const p = row.boonz_products as unknown as { boonz_product_name: string } | null
          const m = row.machines as unknown as { official_name: string } | null
          return {
            pod_inventory_id: row.pod_inventory_id,
            boonz_product_name: p?.boonz_product_name ?? '—',
            machine_name: m?.official_name ?? '—',
            current_stock: row.current_stock ?? 0,
            expiration_date: row.expiration_date,
          }
        })
        setRows(mapped)
      }
      setLoading(false)
    }
    fetchData()
  }, [])

  const filtered = useMemo(() => {
    const today = todayISO()
    let result = rows

    // Search
    if (search.trim()) {
      const q = search.toLowerCase()
      result = result.filter(
        (r) =>
          r.boonz_product_name.toLowerCase().includes(q) ||
          r.machine_name.toLowerCase().includes(q)
      )
    }

    // Expiry filter — cumulative (< 7 days includes < 3 days etc.)
    result = result.filter((r) => {
      const days = daysUntilExpiry(r.expiration_date)
      switch (filter) {
        case 'expired':
          return days !== null && days <= 0
        case '3days':
          return days !== null && days >= 0 && days <= 3
        case '7days':
          return days !== null && days <= 7
        case '30days':
          return days !== null && days <= 30
        case 'all':
          return true
      }
    })

    // Sort: expiry ASC (most urgent first), then machine name ASC
    return [...result].sort((a, b) => {
      const da = daysUntilExpiry(a.expiration_date)
      const db = daysUntilExpiry(b.expiration_date)
      if (da === null && db === null) return a.machine_name.localeCompare(b.machine_name)
      if (da === null) return 1
      if (db === null) return -1
      if (da !== db) return da - db
      return a.machine_name.localeCompare(b.machine_name)
    })
  }, [rows, filter, search])

  const totalUnits = useMemo(
    () => filtered.reduce((sum, r) => sum + r.current_stock, 0),
    [filtered]
  )

  if (loading) {
    return (
      <>
        <FieldHeader title="Machine Stock Expiry" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader title="Machine Stock Expiry" />

      <div className="px-4 py-4">
        {/* Search */}
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search product or machine…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        {/* Filter pills */}
        <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
          {FILTER_OPTIONS.map((f) => (
            <button
              key={f.value}
              onClick={() => setFilter(f.value)}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                filter === f.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        {/* Summary line */}
        {filtered.length > 0 && (
          <p className="mb-3 text-xs text-neutral-500">
            {filtered.length} items · {totalUnits} units at risk
          </p>
        )}

        {/* Results */}
        {filtered.length === 0 ? (
          <div className="flex flex-col items-center justify-center p-8 text-center">
            <p className="text-4xl mb-3">✓</p>
            <p className="text-base font-medium text-neutral-600 dark:text-neutral-400">
              No items in this category
            </p>
            <p className="mt-1 text-sm text-neutral-500">
              {search ? 'Try a different search term' : 'All clear for this range'}
            </p>
          </div>
        ) : (
          <ul className="space-y-2">
            {filtered.map((row) => {
              const days = daysUntilExpiry(row.expiration_date)
              const qtyColour =
                days !== null && days <= 0
                  ? 'text-red-600 dark:text-red-400'
                  : days !== null && days <= 3
                  ? 'text-amber-600 dark:text-amber-400'
                  : 'text-neutral-700 dark:text-neutral-300'

              return (
                <li
                  key={row.pod_inventory_id}
                  className="flex items-start rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  {/* Left side */}
                  <div className="min-w-0 flex-1 pr-3">
                    {/* Line 1: Product name */}
                    <p className="text-sm font-bold truncate">{row.boonz_product_name}</p>

                    {/* Line 2: Machine name */}
                    <p className="mt-0.5 text-xs text-neutral-500 truncate">{row.machine_name}</p>

                    {/* Line 3: Expiry date + badge */}
                    <div className="mt-1.5 flex flex-wrap items-center gap-2">
                      <span className="text-xs text-neutral-400">
                        {formatDate(row.expiration_date)}
                      </span>
                      <PodExpiryBadge days={days} />
                    </div>
                  </div>

                  {/* Right side: qty — large + bold */}
                  <div className={`flex shrink-0 flex-col items-end ${qtyColour}`}>
                    <p className="text-xl font-bold leading-none">{row.current_stock}</p>
                    <p className="mt-0.5 text-xs opacity-60">units</p>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </div>
    </div>
  )
}
