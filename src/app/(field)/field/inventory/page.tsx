'use client'

import { useEffect, useState, useCallback, useMemo } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'

interface InventoryRow {
  wh_inventory_id: string
  boonz_product_name: string
  product_category: string | null
  batch_id: string
  wh_location: string | null
  warehouse_stock: number
  expiration_date: string | null
}

type ExpiryFilter = 'all' | 'expired' | '3days' | '7days' | '30days'
type SortOption = 'expiry' | 'name' | 'qty'

const expiryFilters: { label: string; value: ExpiryFilter }[] = [
  { label: 'All', value: 'all' },
  { label: 'Expired', value: 'expired' },
  { label: '≤3 days', value: '3days' },
  { label: '≤7 days', value: '7days' },
  { label: '≤30 days', value: '30days' },
]

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

function ExpiryBadge({ days }: { days: number | null }) {
  if (days === null) return null
  if (days <= 0) {
    return (
      <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
        Expired
      </span>
    )
  }
  if (days <= 3) {
    return (
      <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900 dark:text-amber-300">
        Expiring soon
      </span>
    )
  }
  if (days <= 7) {
    return (
      <span className="rounded-full bg-orange-100 px-2 py-0.5 text-xs font-medium text-orange-700 dark:bg-orange-900 dark:text-orange-300">
        This week
      </span>
    )
  }
  return null
}

export default function InventoryPage() {
  const [rows, setRows] = useState<InventoryRow[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>('7days')
  const [sortBy, setSortBy] = useState<SortOption>('expiry')
  const [hideEmpty, setHideEmpty] = useState(true)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const { data } = await supabase
      .from('warehouse_inventory')
      .select(`
        wh_inventory_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        boonz_products!inner(boonz_product_name, product_category)
      `)
      .eq('status', 'Active')

    if (!data || data.length === 0) {
      setRows([])
      setLoading(false)
      return
    }

    const mapped: InventoryRow[] = data.map((row) => {
      const p = row.boonz_products as unknown as {
        boonz_product_name: string
        product_category: string | null
      }
      return {
        wh_inventory_id: row.wh_inventory_id,
        boonz_product_name: p.boonz_product_name,
        product_category: p.product_category,
        batch_id: row.batch_id ?? '',
        wh_location: row.wh_location,
        warehouse_stock: row.warehouse_stock ?? 0,
        expiration_date: row.expiration_date,
      }
    })

    setRows(mapped)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchData()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchData)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchData)
    }
  }, [fetchData])

  const processed = useMemo(() => {
    let filtered = rows

    // Hide empty
    if (hideEmpty) {
      filtered = filtered.filter((r) => r.warehouse_stock > 0)
    }

    // Search filter
    if (search.trim()) {
      const q = search.toLowerCase()
      filtered = filtered.filter((r) =>
        r.boonz_product_name.toLowerCase().includes(q)
      )
    }

    // Expiry filter
    filtered = filtered.filter((r) => {
      if (expiryFilter === 'all') return true
      const days = daysUntilExpiry(r.expiration_date)
      if (days === null) return false
      switch (expiryFilter) {
        case 'expired': return days <= 0
        case '3days': return days <= 3
        case '7days': return days <= 7
        case '30days': return days <= 30
      }
    })

    // Sort
    filtered = [...filtered].sort((a, b) => {
      switch (sortBy) {
        case 'expiry': {
          const da = daysUntilExpiry(a.expiration_date)
          const db = daysUntilExpiry(b.expiration_date)
          if (da === null && db === null) return 0
          if (da === null) return 1
          if (db === null) return -1
          return da - db
        }
        case 'name':
          return a.boonz_product_name.localeCompare(b.boonz_product_name)
        case 'qty':
          return b.warehouse_stock - a.warehouse_stock
      }
    })

    // Group by wh_location
    const groups = new Map<string, InventoryRow[]>()
    for (const row of filtered) {
      const loc = row.wh_location || 'Unassigned'
      const existing = groups.get(loc) ?? []
      existing.push(row)
      groups.set(loc, existing)
    }

    return Array.from(groups.entries()).sort((a, b) =>
      a[0].localeCompare(b[0])
    )
  }, [rows, search, expiryFilter, sortBy, hideEmpty])

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading inventory…</p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="mb-3 text-xl font-semibold">Inventory</h1>

      {/* Search */}
      <input
        type="text"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        placeholder="Search products…"
        className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
      />

      {/* Expiry filter pills */}
      <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
        {expiryFilters.map((f) => (
          <button
            key={f.value}
            onClick={() => setExpiryFilter(f.value)}
            className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
              expiryFilter === f.value
                ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      {/* Hide empty toggle */}
      <div className="mb-3 flex gap-2">
        <button
          onClick={() => setHideEmpty(true)}
          className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
            hideEmpty
              ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
              : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
          }`}
        >
          Hide empty
        </button>
        <button
          onClick={() => setHideEmpty(false)}
          className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
            !hideEmpty
              ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
              : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
          }`}
        >
          Show all
        </button>
      </div>

      {/* Sort */}
      <div className="mb-4 flex items-center gap-2 text-xs text-neutral-500">
        <span>Sort:</span>
        {([
          { label: 'Expiry', value: 'expiry' as SortOption },
          { label: 'Name', value: 'name' as SortOption },
          { label: 'Qty', value: 'qty' as SortOption },
        ]).map((s) => (
          <button
            key={s.value}
            onClick={() => setSortBy(s.value)}
            className={`rounded px-2 py-1 transition-colors ${
              sortBy === s.value
                ? 'bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100'
                : 'hover:bg-neutral-100 dark:hover:bg-neutral-800'
            }`}
          >
            {s.label}
          </button>
        ))}
      </div>

      {/* Results */}
      {processed.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No items match this filter
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            {search ? 'Try a different search term' : 'Try a different expiry range'}
          </p>
        </div>
      ) : (
        processed.map(([location, items]) => (
          <div key={location} className="mb-5">
            <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
              {location} ({items.length} {items.length === 1 ? 'item' : 'items'})
            </h2>
            <ul className="space-y-2">
              {items.map((row) => {
                const days = daysUntilExpiry(row.expiration_date)
                return (
                  <li key={row.wh_inventory_id}>
                    <Link
                      href={`/field/inventory/${row.wh_inventory_id}`}
                      className="block rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
                    >
                      <div className="flex items-start justify-between gap-2">
                        <div className="min-w-0 flex-1">
                          <p className="text-sm font-semibold truncate">
                            {row.boonz_product_name}
                          </p>
                          {row.product_category && (
                            <p className="text-xs text-neutral-400 mt-0.5">
                              {row.product_category}
                            </p>
                          )}
                          <p className="text-xs text-neutral-400 mt-0.5">
                            {row.batch_id || 'No batch'}
                          </p>
                        </div>
                        <div className="shrink-0 text-right">
                          <p className="text-sm font-semibold">
                            {row.warehouse_stock} units
                          </p>
                          <ExpiryBadge days={days} />
                        </div>
                      </div>
                      <p className="mt-1 text-xs text-neutral-500">
                        Expires: {formatDate(row.expiration_date)}
                      </p>
                    </Link>
                  </li>
                )
              })}
            </ul>
          </div>
        ))
      )}
    </div>
  )
}
