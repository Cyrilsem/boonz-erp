'use client'

import { useEffect, useState, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface InventoryRow {
  inventory_id: string
  boonz_product_name: string
  batch_id: string
  wh_location: string | null
  warehouse_stock: number
  expiration_date: string | null
  status: string
}

type FilterOption = 'all' | 'today' | '3days' | '7days' | '30days'

const filters: { label: string; value: FilterOption }[] = [
  { label: 'All active', value: 'all' },
  { label: 'Today', value: 'today' },
  { label: '3 days', value: '3days' },
  { label: '7 days', value: '7days' },
  { label: '30 days', value: '30days' },
]

function daysUntilExpiry(expirationDate: string | null): number | null {
  if (!expirationDate) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(expirationDate + 'T00:00:00')
  const diff = exp.getTime() - today.getTime()
  return Math.ceil(diff / (1000 * 60 * 60 * 24))
}

function expiryColor(days: number | null): string {
  if (days === null) return 'text-neutral-500'
  if (days <= 0) return 'text-red-600 dark:text-red-400'
  if (days <= 3) return 'text-amber-600 dark:text-amber-400'
  if (days <= 7) return 'text-orange-600 dark:text-orange-400'
  return 'text-neutral-600 dark:text-neutral-400'
}

function expiryLabel(days: number | null): string {
  if (days === null) return 'No expiry'
  if (days < 0) return `Expired ${Math.abs(days)}d ago`
  if (days === 0) return 'Expires today'
  return `${days}d left`
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

export default function ExpiryPage() {
  const [rows, setRows] = useState<InventoryRow[]>([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState<FilterOption>('7days')
  const [removing, setRemoving] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const { data } = await supabase
      .from('warehouse_inventory')
      .select(`
        inventory_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        status,
        boonz_products!inner(boonz_product_name)
      `)
      .eq('status', 'Active')

    if (!data || data.length === 0) {
      setRows([])
      setLoading(false)
      return
    }

    const mapped: InventoryRow[] = data.map((row) => {
      const p = row.boonz_products as unknown as { boonz_product_name: string }
      return {
        inventory_id: row.inventory_id,
        boonz_product_name: p.boonz_product_name,
        batch_id: row.batch_id ?? '',
        wh_location: row.wh_location,
        warehouse_stock: row.warehouse_stock ?? 0,
        expiration_date: row.expiration_date,
        status: row.status,
      }
    })

    mapped.sort((a, b) => {
      const da = daysUntilExpiry(a.expiration_date)
      const db = daysUntilExpiry(b.expiration_date)
      if (da === null && db === null) return a.boonz_product_name.localeCompare(b.boonz_product_name)
      if (da === null) return 1
      if (db === null) return -1
      return da - db
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

  async function handleRemove(inventoryId: string) {
    setRemoving(inventoryId)
    const supabase = createClient()

    await supabase
      .from('warehouse_inventory')
      .update({ status: 'Expired' })
      .eq('inventory_id', inventoryId)

    setRows((prev) => prev.filter((r) => r.inventory_id !== inventoryId))
    setRemoving(null)
  }

  const filtered = rows.filter((row) => {
    if (filter === 'all') return true
    const days = daysUntilExpiry(row.expiration_date)
    if (days === null) return false
    switch (filter) {
      case 'today':
        return days <= 0
      case '3days':
        return days <= 3
      case '7days':
        return days <= 7
      case '30days':
        return days <= 30
    }
  })

  if (loading) {
    return (
      <>
        <FieldHeader title="Expiry" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading inventory…</p>
        </div>
      </>
    )
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Expiry" />

      <div className="mb-4 flex gap-2 overflow-x-auto pb-1">
        {filters.map((f) => (
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

      {filtered.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No items match this filter
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            {filter === 'all' ? 'No active inventory' : 'Try a different time range'}
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {filtered.map((row) => {
            const days = daysUntilExpiry(row.expiration_date)
            return (
              <li
                key={row.inventory_id}
                className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-semibold truncate">
                      {row.boonz_product_name}
                    </p>
                    <p className="text-xs text-neutral-500 mt-0.5">
                      Batch: {row.batch_id || '—'}
                    </p>
                    <div className="mt-1 flex items-center gap-3 text-xs text-neutral-500">
                      {row.wh_location && <span>{row.wh_location}</span>}
                      <span>Qty: {row.warehouse_stock}</span>
                    </div>
                    <div className="mt-1 flex items-center gap-2">
                      <span className={`text-xs font-medium ${expiryColor(days)}`}>
                        {expiryLabel(days)}
                      </span>
                      <span className="text-xs text-neutral-400">
                        {formatDate(row.expiration_date)}
                      </span>
                    </div>
                  </div>
                  <button
                    onClick={() => handleRemove(row.inventory_id)}
                    disabled={removing === row.inventory_id}
                    className="shrink-0 rounded-lg border border-red-200 px-3 py-1.5 text-xs font-medium text-red-600 transition-colors hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-900/30"
                  >
                    {removing === row.inventory_id ? 'Removing…' : 'Remove'}
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
