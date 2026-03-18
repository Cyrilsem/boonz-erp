'use client'

import { useEffect, useState, useCallback, useMemo } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface InventoryRow {
  wh_inventory_id: string
  boonz_product_id: string
  boonz_product_name: string
  product_category: string | null
  batch_id: string
  wh_location: string | null
  warehouse_stock: number
  expiration_date: string | null
  status: string
}

interface ControlEdit {
  qty: number
  location: string
  status: string
}

type ExpiryFilter = 'all' | 'expired' | '3days' | '7days' | '30days'
type SortOption = 'expiry' | 'location' | 'name' | 'qty_high' | 'qty_low'
type StatusFilter = 'Active' | 'Inactive' | 'all'

const expiryFilters: { label: string; value: ExpiryFilter }[] = [
  { label: 'All', value: 'all' },
  { label: 'Expired', value: 'expired' },
  { label: '<=3 days', value: '3days' },
  { label: '<=7 days', value: '7days' },
  { label: '<=30 days', value: '30days' },
]

function daysUntilExpiry(date: string | null): number | null {
  if (!date) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(date + 'T00:00:00')
  return Math.ceil((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24))
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '\u2014'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

interface ExpiryStyle {
  badgeBg: string
  badgeText: string
  label: string
  qtyColor: string
}

function getExpiryStyle(expiryDate: string | null): ExpiryStyle {
  if (!expiryDate) return { badgeBg: '', badgeText: '', label: '', qtyColor: 'text-gray-700' }
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(expiryDate + 'T00:00:00')
  exp.setHours(0, 0, 0, 0)
  const diffDays = Math.floor((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24))
  if (diffDays < 0)  return { badgeBg: 'bg-red-100',    badgeText: 'text-red-700',    label: 'Expired',          qtyColor: 'text-red-600'    }
  if (diffDays === 0) return { badgeBg: 'bg-red-50',     badgeText: 'text-red-400',    label: 'Today',            qtyColor: 'text-red-400'    }
  if (diffDays <= 3)  return { badgeBg: 'bg-red-50',     badgeText: 'text-red-400',    label: `${diffDays}d left`, qtyColor: 'text-red-400'   }
  if (diffDays <= 7)  return { badgeBg: 'bg-yellow-50',  badgeText: 'text-yellow-600', label: `${diffDays}d left`, qtyColor: 'text-yellow-600' }
  if (diffDays <= 30) return { badgeBg: 'bg-lime-50',    badgeText: 'text-lime-600',   label: `${diffDays}d left`, qtyColor: 'text-lime-600'  }
  return                     { badgeBg: 'bg-green-50',   badgeText: 'text-green-600',  label: `${diffDays}d left`, qtyColor: 'text-green-600' }
}

function ExpiryBadge({ expiryDate }: { expiryDate: string | null }) {
  const style = getExpiryStyle(expiryDate)
  if (!style.label) return null
  return (
    <span className={`rounded-full ${style.badgeBg} px-2 py-0.5 text-xs font-medium ${style.badgeText}`}>
      {style.label}
    </span>
  )
}

export default function InventoryPage() {
  const [rows, setRows] = useState<InventoryRow[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>('7days')
  const [sortBy, setSortBy] = useState<SortOption>('expiry')
  const [hideEmpty, setHideEmpty] = useState(true)
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('Active')

  // Inventory control mode
  const [controlMode, setControlMode] = useState(false)
  const [controlEdits, setControlEdits] = useState<Map<string, ControlEdit>>(new Map())
  const [controlSaving, setControlSaving] = useState(false)
  const [controlMessage, setControlMessage] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const query = supabase
      .from('warehouse_inventory')
      .select(`
        wh_inventory_id,
        boonz_product_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        status,
        boonz_products!inner(boonz_product_name, product_category)
      `)

    if (statusFilter !== 'all') {
      query.eq('status', statusFilter)
    } else {
      query.in('status', ['Active', 'Inactive'])
    }

    const { data } = await query

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
        boonz_product_id: row.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        product_category: p.product_category,
        batch_id: row.batch_id ?? '',
        wh_location: row.wh_location,
        warehouse_stock: row.warehouse_stock ?? 0,
        expiration_date: row.expiration_date,
        status: row.status ?? 'Active',
      }
    })

    setRows(mapped)
    setLoading(false)
  }, [statusFilter])

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

  // Enter control mode: initialize edits from current rows
  function enterControlMode() {
    const edits = new Map<string, ControlEdit>()
    for (const row of rows) {
      edits.set(row.wh_inventory_id, {
        qty: row.warehouse_stock,
        location: row.wh_location ?? '',
        status: row.status,
      })
    }
    setControlEdits(edits)
    setControlMode(true)
  }

  function updateControlEdit(id: string, field: keyof ControlEdit, value: string | number) {
    setControlEdits((prev) => {
      const next = new Map(prev)
      const existing = next.get(id)
      if (existing) {
        next.set(id, { ...existing, [field]: value })
      }
      return next
    })
  }

  async function completeControl() {
    setControlSaving(true)
    const supabase = createClient()

    const { data: { user } } = await supabase.auth.getUser()
    const userId = user?.id

    for (const row of rows) {
      const edit = controlEdits.get(row.wh_inventory_id)
      if (!edit) continue

      const qtyChanged = edit.qty !== row.warehouse_stock
      const locationChanged = (edit.location || null) !== (row.wh_location || null)
      const statusChanged = edit.status !== row.status

      if (!qtyChanged && !locationChanged && !statusChanged) continue

      // Update the inventory row
      const updates: Record<string, unknown> = {}
      if (qtyChanged) updates.warehouse_stock = edit.qty
      if (locationChanged) updates.wh_location = edit.location || null
      if (statusChanged) updates.status = edit.status

      await supabase
        .from('warehouse_inventory')
        .update(updates)
        .eq('wh_inventory_id', row.wh_inventory_id)

      // Insert audit log
      await supabase.from('inventory_audit_log').insert({
        wh_inventory_id: row.wh_inventory_id,
        boonz_product_id: row.boonz_product_id,
        old_qty: row.warehouse_stock,
        new_qty: edit.qty,
        reason: 'Inventory control',
      })
    }

    // Insert inventory control log
    if (userId) {
      await supabase.from('inventory_control_log').insert({
        conducted_by: userId,
        notes: null,
      })
    }

    setControlMode(false)
    setControlEdits(new Map())
    setControlSaving(false)
    setControlMessage('Inventory control logged')
    await fetchData()

    setTimeout(() => setControlMessage(null), 3000)
  }

  const processed: InventoryRow[] = useMemo(() => {
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
        case 'location': {
          const la = a.wh_location ?? ''
          const lb = b.wh_location ?? ''
          return la.localeCompare(lb)
        }
        case 'name':
          return a.boonz_product_name.localeCompare(b.boonz_product_name)
        case 'qty_high':
          return b.warehouse_stock - a.warehouse_stock
        case 'qty_low':
          return a.warehouse_stock - b.warehouse_stock
      }
    })

    return filtered
  }, [rows, search, expiryFilter, sortBy, hideEmpty])

  if (loading) {
    return (
      <>
        <FieldHeader title="Inventory" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading inventory...</p>
        </div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Inventory"
        rightAction={
          !controlMode ? (
            <button
              onClick={enterControlMode}
              className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
            >
              + Inventory Control
            </button>
          ) : (
            <button
              onClick={() => { setControlMode(false); setControlEdits(new Map()) }}
              className="rounded-lg bg-neutral-200 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-300 dark:bg-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-600"
            >
              Cancel
            </button>
          )
        }
      />

      <div className="px-4 py-4">
        {/* Control mode message */}
        {controlMessage && (
          <div className="mb-3 rounded-lg bg-green-100 px-3 py-2 text-sm font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
            {controlMessage}
          </div>
        )}

        {/* Search */}
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search products..."
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        {/* Status filter pills */}
        <div className="mb-3 flex gap-2">
          {([
            { label: 'Active', value: 'Active' as StatusFilter },
            { label: 'Inactive', value: 'Inactive' as StatusFilter },
            { label: 'All', value: 'all' as StatusFilter },
          ]).map((s) => (
            <button
              key={s.value}
              onClick={() => setStatusFilter(s.value)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                statusFilter === s.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>

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
            { label: 'Location', value: 'location' as SortOption },
            { label: 'Name', value: 'name' as SortOption },
            { label: 'Qty High', value: 'qty_high' as SortOption },
            { label: 'Qty Low', value: 'qty_low' as SortOption },
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
          <ul className="space-y-2">
            {processed.map((row) => {
              const edit = controlEdits.get(row.wh_inventory_id)

              if (controlMode && edit) {
                return (
                  <li
                    key={row.wh_inventory_id}
                    className="rounded-lg border border-blue-200 bg-blue-50/50 p-4 dark:border-blue-900 dark:bg-blue-950/30"
                  >
                    {/* Line 1: Product name */}
                    <p className="text-sm font-bold truncate">{row.boonz_product_name}</p>

                    {/* Line 2: Location badge + category + batch */}
                    <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                      <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                        {row.wh_location || 'Unassigned'}
                      </span>
                      {row.product_category && (
                        <>
                          <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                          <span className="text-neutral-500">{row.product_category}</span>
                        </>
                      )}
                      <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                      <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                    </div>

                    {/* Editable fields */}
                    <div className="mt-3 grid grid-cols-3 gap-2">
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Qty</label>
                        <input
                          type="number"
                          min={0}
                          value={edit.qty}
                          onChange={(e) =>
                            updateControlEdit(row.wh_inventory_id, 'qty', parseInt(e.target.value, 10) || 0)
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Location</label>
                        <input
                          type="text"
                          value={edit.location}
                          onChange={(e) =>
                            updateControlEdit(row.wh_inventory_id, 'location', e.target.value)
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Status</label>
                        <button
                          onClick={() =>
                            updateControlEdit(
                              row.wh_inventory_id,
                              'status',
                              edit.status === 'Active' ? 'Inactive' : 'Active'
                            )
                          }
                          className={`w-full rounded px-2 py-1.5 text-sm font-medium ${
                            edit.status === 'Active'
                              ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                              : 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400'
                          }`}
                        >
                          {edit.status}
                        </button>
                      </div>
                    </div>
                  </li>
                )
              }

              // Normal (non-control) row
              return (
                <li key={row.wh_inventory_id}>
                  <Link
                    href={`/field/inventory/${row.wh_inventory_id}`}
                    className="flex items-start rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
                  >
                    {/* Left side */}
                    <div className="min-w-0 flex-1 pr-3">
                      {/* Line 1: Product name */}
                      <p className="text-sm font-bold truncate">{row.boonz_product_name}</p>

                      {/* Line 2: Location badge + category + batch */}
                      <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                        <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                          {row.wh_location || 'Unassigned'}
                        </span>
                        {row.product_category && (
                          <>
                            <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                            <span className="text-neutral-500">{row.product_category}</span>
                          </>
                        )}
                        <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                        <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                      </div>

                      {/* Line 3: Expiry + badges */}
                      <div className="mt-1.5 flex flex-wrap items-center gap-2 text-xs">
                        <span className="text-neutral-500">{formatDate(row.expiration_date)}</span>
                        <ExpiryBadge expiryDate={row.expiration_date} />
                        {row.status === 'Inactive' && (
                          <span className="rounded-full bg-amber-100 px-2 py-0.5 font-medium text-amber-700 dark:bg-amber-900 dark:text-amber-300">
                            Inactive
                          </span>
                        )}
                      </div>
                    </div>

                    {/* Right side: qty */}
                    <div className={`flex shrink-0 flex-col items-end ${getExpiryStyle(row.expiration_date).qtyColor}`}>
                      <p className="text-xl font-bold leading-none">{row.warehouse_stock}</p>
                      <p className="mt-0.5 text-xs opacity-60">units</p>
                    </div>
                  </Link>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      {/* Floating "Complete control" button */}
      {controlMode && (
        <div className="fixed inset-x-0 bottom-20 z-30 px-4">
          <button
            onClick={completeControl}
            disabled={controlSaving}
            className="w-full rounded-xl bg-blue-600 py-3 text-sm font-semibold text-white shadow-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {controlSaving ? 'Saving...' : 'Complete control'}
          </button>
        </div>
      )}
    </div>
  )
}
